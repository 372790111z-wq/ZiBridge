import Foundation
final class CommandLog { var names:[String]=[] }
final class FakeWorkbenchOutput: WorkbenchAudioOutput {
    var pending = 0, pushes = 0, closed = 0
    var failOnPush = false, routeFails = false
    func validateRoute() throws {if routeFails {throw ProbeError.invalid("fake_route_failure")}}
    func push(_ pcm: [Float]) throws {
        if failOnPush { throw ProbeError.invalid("fake_output_failure") }
        pushes += 1
    }
    func close() { closed += 1 }
}
func requestName(_ r:Request)->String{
    switch r {
    case .info:return "info"
    case .startOwned:return "start"
    case .pauseOwned:return "pause"
    case .stopOwned:return "stop"
    case .handshake:return "handshake"
    case .earlyLiveOwned:return "early"
    case .live:return "live"
    case .finished:return "finished"
    }
}
func pilotTests()throws{
    var count=0
    func check(_ b:@autoclosure()throws->Bool,_ name:String)throws{guard try b()else{throw ProbeError.invalid("test_"+name)};count+=1}
    func rejects(_ name:String,_ f:()throws->Void)throws{do{try f()}catch{count+=1;return};throw ProbeError.invalid("accepted_"+name)}
    func active()throws->PilotPolicy{var p=PilotPolicy();try p.start(firmwareOK:true,idle:true);try p.acknowledgeStart();try p.opened(123);return p}
    // Real safety policy: unrelated music changes do not invalidate the bound
    // microphone, but target loss/rebinding/mixing remain hard failures.
    for music:UInt32? in [UInt32(1),UInt32(2),nil,UInt32(3),UInt32(1)] {
        try validateIndependentOutputRoute(target:10,bound:10,uid:"BlackHole2ch_UID",musicOutput:music)
        try check(true,"independent_music_route")
    }
    try rejects("music_mixed_into_microphone") {try validateIndependentOutputRoute(target:10,bound:10,uid:"BlackHole2ch_UID",musicOutput:10)}
    try rejects("bound_device_unreadable") {try validateIndependentOutputRoute(target:10,bound:nil,uid:"BlackHole2ch_UID",musicOutput:2)}
    try rejects("bound_device_redirected") {try validateIndependentOutputRoute(target:10,bound:2,uid:"BlackHole2ch_UID",musicOutput:2)}
    try rejects("bound_uid_unreadable") {try validateIndependentOutputRoute(target:10,bound:10,uid:nil,musicOutput:2)}
    try rejects("bound_uid_reused_id") {try validateIndependentOutputRoute(target:10,bound:10,uid:"speaker",musicOutput:2)}
    var p=PilotPolicy()
    try rejects("unowned_stop"){try p.requestStop()}
    try rejects("already_recording"){try p.start(firmwareOK:true,idle:false)}
    try rejects("firmware"){try p.start(firmwareOK:false,idle:true)}
    try p.start(firmwareOK:true,idle:true)
    try rejects("start_without_id_stop"){try p.requestStop()}
    try rejects("invalid_id"){try p.opened(0)}
    try rejects("no_start_ack"){try p.opened(123)}
    try p.acknowledgeStart()
    try p.opened(123)
    try rejects("new_id_midstream"){try p.opened(456)}
    try p.frame(seq:24,flags:0);try check(p.prefixFramesMissing==24 && !p.fromStartComplete,"prefix_not_hidden")
    try rejects("repeat"){try p.frame(seq:24,flags:0)}
    try rejects("out_of_order"){try p.frame(seq:23,flags:0)}
    try rejects("gap"){try p.frame(seq:26,flags:0)}
    var q=try active();try q.frame(seq:0,flags:2);try q.frame(seq:1,flags:4)
    try rejects("after_tail"){try q.frame(seq:2,flags:0)}
    try q.requestStop();try rejects("duplicate_stop"){try q.requestStop()}
    try q.observeStop();try rejects("wrong_terminal"){try q.terminal(124)}
    try check(!q.protocolAudioComplete,"stop_without_terminal_not_audio_complete")
    try q.terminal(123);try q.verifyRequested()
    try rejects("not_idle"){try q.verifiedIdle(false)}
    try q.verifiedIdle(true);try check(!q.ownsStart && q.state == .ended,"closed")
    try rejects("old_tail"){try q.terminal(123)}
    var missingTail=try active();try missingTail.frame(seq:24,flags:0);try missingTail.requestStop();try missingTail.observeStop();try missingTail.terminal(123);try missingTail.verifyRequested()
    try check(missingTail.state == .verifying && !missingTail.lastFlag,"verify_stop_without_inventing_tail")
    try missingTail.frame(seq:25,flags:0);try missingTail.verifiedIdle(true)
    try check(missingTail.state == .ended && !missingTail.lastFlag && !missingTail.fromStartComplete,"idle_not_audio_complete")
    var noStop=try active();try noStop.terminal(123);try rejects("terminal_alone_not_stop"){try noStop.verifyRequested()}
    var invalid=try active();try rejects("flag"){try invalid.frame(seq:0,flags:8)}
    try rejects("first_nonzero"){try invalid.frame(seq:4,flags:2)}
    var cap=try active();for i in 0..<1500{try cap.frame(seq:UInt32(i),flags:i==0 ? 2:0)}
    try rejects("frame_budget"){try cap.frame(seq:1500,flags:0)}
    var budget=QueueBudget();for _ in 0..<8{try budget.acquire()};try rejects("unbounded_queue"){try budget.acquire()};budget.release();try budget.acquire();try check(budget.peak==8,"queue_peak")
    try check(percentile([1,2,3,4],0.95)==4,"percentile")
    try check(percentile([],0.95)==nil,"empty_percentile")
    try check(abs((streamAttachLag(startToFirstPCM:1.290864,firstSequence:36) ?? 0)-0.570864)<1e-9,"attach_lag_matches_same_recording_sample")
    try check(abs((streamAttachLag(startToFirstPCM:1.050993,firstSequence:24) ?? 0)-0.570993)<1e-9,"attach_lag_matches_tail_arrival_sample")
    try check(streamAttachLag(startToFirstPCM:nil,firstSequence:24)==nil && streamAttachLag(startToFirstPCM:1,firstSequence:nil)==nil,"attach_lag_unknown_stays_missing")
    try check(streamAttachLag(startToFirstPCM:.nan,firstSequence:0)==nil && streamAttachLag(startToFirstPCM:1,firstSequence:1500)==nil,"attach_lag_rejects_invalid_clock_or_sequence")
    try check(streamAttachLag(startToFirstPCM:-0.1,firstSequence:0)==nil,"attach_lag_rejects_negative_clock")
    try check(try Request.startOwned.encoded()==[8,238,0,0,0,24,130,11,0,1,156],"start_bytes")
    try check(try Request.stopOwned.encoded()==[8,238,0,0,0,24,130,11,0,0,155],"stop_bytes")
    let inspect = try PilotOptions(["inspect","--device",UUID().uuidString])
    try check(inspect.inspectOnly && inspect.seconds==0 && inspect.output==nil,"inspect_readonly_options")
    try rejects("inspect_extra_options"){_ = try PilotOptions(["inspect","--device",UUID().uuidString,"--public-session"])}
    try rejects("bad_args"){_ = try PilotOptions(["live-pilot"])}
    try rejects("nan_seconds"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","nan","--public-session"])}
    try rejects("too_long"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","30","--public-session"])}
    try rejects("no_ack"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","10"])}
    var stoppedNoStream=try active();try stoppedNoStream.requestStop();try stoppedNoStream.observeStop();try stoppedNoStream.verifyRequested();try stoppedNoStream.verifiedIdle(true)
    try check(stoppedNoStream.state == .ended && !stoppedNoStream.protocolAudioComplete,"idle_does_not_need_transfer")
    try check(try !stoppedNoStream.observeStop(),"duplicate_stop_after_idle_no_state_regression")
    try check(stoppedNoStream.state == .ended,"duplicate_stop_preserves_idle")
    try stoppedNoStream.terminal(123)
    try check(!stoppedNoStream.protocolAudioComplete,"late_terminal_not_fake_audio")
    let delayed=try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","5","--public-session","--early-live","--early-live-delay-ms","300"])
    try check(delayed.earlyDelay==0.3,"explicit_delay")
    try rejects("delay_without_early"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","5","--public-session","--early-live-delay-ms","300"])}
    try rejects("delay_nan"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","5","--public-session","--early-live","--early-live-delay-ms","nan"])}
    let earlyOptions=try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session","--early-live"])
    try check(earlyOptions.earlyLive && earlyOptions.output==nil,"early_is_explicit")
    try rejects("duplicate_early"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session","--early-live","--early-live"])}
    try rejects("early_inspect_forbidden"){_ = try PilotOptions(["inspect","--device",UUID().uuidString,"--early-live"])}
    try rejects("unverified_early_output"){_ = try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session","--early-live","--output-uid","BlackHole2ch_UID"])}
    var ownership=PilotPolicy();try check(!ownership.canRequestEarlyLive,"early_requires_ownership")
    try ownership.start(firmwareOK:true,idle:true);try check(!ownership.canRequestEarlyLive,"early_requires_start_ack")
    try ownership.acknowledgeStart();try check(ownership.canRequestEarlyLive,"early_owned_ack_allowed")
    try ownership.opened(123);try check(!ownership.canRequestEarlyLive,"early_cannot_restart_stream")
    let ewire=try Request.earlyLiveOwned.encoded()
    try check(ewire[5]==0x1a && ewire[6]==7 && ewire[17]==1 && u32(ewire,13)==0,"early_is_only_current_live_not_offline")
    let eh=le32(123)+le32(UInt32.max)+Array(repeating:UInt8(0),count:79)
    var eb=EarlyLiveBuffer()
    try rejects("early_audio_before_head"){try eb.append(Array(repeating:0,count:166))}
    try rejects("early_release_without_identity"){_ = try eb.release(matching:123)}
    try eb.acceptHead(eh)
    try rejects("early_duplicate_head"){try eb.acceptHead(eh)}
    try eb.append(Array(repeating:0,count:166*64))
    try check(eb.frames==64 && !eb.released,"early_buffer_is_bounded_ciphertext")
    try rejects("early_limit"){try eb.append(Array(repeating:0,count:166))}
    try rejects("early_wrong_session"){_ = try eb.release(matching:124)}
    let (_, encrypted)=try eb.release(matching:123)
    try check(encrypted.count==1 && eb.head==nil && eb.packets.isEmpty,"early_exact_session_release")
    try rejects("early_double_release"){_ = try eb.release(matching:123)}
    try rejects("early_reuse"){try eb.append(Array(repeating:0,count:166))}
    var discard=EarlyLiveBuffer();try discard.acceptHead(eh);discard.discard()
    try check(discard.head==nil && discard.packets.isEmpty,"discard_no_audio_retained")
    try rejects("discard_no_release"){_ = try discard.release(matching:123)}
    var wrong=EarlyLiveBuffer()
    try rejects("early_reserved_file"){try wrong.acceptHead(le32(0)+Array(eh.dropFirst(4)))}
    try rejects("early_finite_file"){try wrong.acceptHead(le32(123)+le32(166)+Array(eh.dropFirst(8)))}
    try rejects("early_bad_head_size"){try wrong.acceptHead(Array(eh.dropLast()))}
    // Diagnostics must distinguish concurrent faults without admitting any of them.
    func observed(_ body:[UInt8], expected:UInt32?=nil, status:UInt8=1)->[String:Any] {
        var diagnostics=HeadDiagnostics()
        return diagnostics.observe(Packet(status:status,type:0x1a,id:7,payload:body),expected:expected,early:true)!
    }
    var errorHead=le32(0)+le32(UInt32.max)+Array(repeating:UInt8(0xa5),count:78)+[7]
    let zeroError=observed(errorHead)
    try check(zeroError["id_class"] as? String == "zero" && zeroError["head_error_code"] as? Int == 7,"zero_id_does_not_hide_device_error")
    try check(zeroError["session_match"] as? String == "invalid_id" && zeroError["size_class"] as? String == "live_sentinel","reserved_id_not_current_session")
    do {try wrong.acceptHead(errorHead);throw ProbeError.invalid("accepted_zero_error")} catch {
        try check((error as? ProbeError)?.description == "early_head_invalid_id","original_first_error_preserved")
    }
    errorHead.replaceSubrange(0..<4,with:le32(UInt32.max))
    try check(observed(errorHead)["id_class"] as? String == "all_ones","all_ones_distinct_from_zero")
    try rejects("all_ones_error_still_rejected"){try wrong.acceptHead(errorHead)}
    let validObserved=observed(eh,expected:123)
    try check(validObserved["session_match"] as? String == "matches","matching_head_metadata")
    try check(observed(eh,expected:124)["session_match"] as? String == "mismatch","wrong_session_metadata")
    try check(observed(eh)["session_match"] as? String == "awaiting_new_recording","head_alone_not_identity_proof")
    try check(observed(le32(123)+le32(0)+Array(eh.dropFirst(8)))["size_class"] as? String == "zero","zero_size_metadata")
    try check(observed(le32(123)+le32(166)+Array(eh.dropFirst(8)))["size_class"] as? String == "finite_nonzero","offline_size_not_live")
    for length in [0,1,4,8,86,88,4096] {
        let fields=observed(Array(repeating:0xa5,count:length))
        try check(fields["head_error_code"]==nil && fields["id_class"]==nil && fields["size_class"]==nil,"unknown_layout_not_parsed_\(length)")
    }
    let singleFF=observed([0xff])
    try check(singleFF["shape"] as? String == "single_ff_rejection" && singleFF["envelope_accepted"] as? Bool == false,"single_ff_is_rejection_not_head_error")
    let rejectedEnvelope=observed(eh,status:0xa2)
    try check(rejectedEnvelope["envelope_status_low_nibble"] as? Int == 2 && rejectedEnvelope["envelope_accepted"] as? Bool == false,"envelope_rejection_independent_of_head")
    let allowedKeys:Set<String>=["ordinal","subscription","payload_bytes","envelope_status_low_nibble","envelope_accepted","shape","id_class","session_match","size_class","head_error_code"]
    try check(Set(zeroError.keys)==allowedKeys,"diagnostic_field_allowlist")
    var alternateSecrets=errorHead
    alternateSecrets.replaceSubrange(0..<4,with:le32(0))
    alternateSecrets.replaceSubrange(8..<86,with:Array(repeating:0x5a,count:78))
    let firstJSON=try JSONSerialization.data(withJSONObject:zeroError,options:.sortedKeys)
    let otherJSON=try JSONSerialization.data(withJSONObject:observed(alternateSecrets),options:.sortedKeys)
    try check(firstJSON==otherJSON,"nonce_and_wrapped_key_never_affect_telemetry")
    try check(try JSONSerialization.data(withJSONObject:observed(eh),options:.sortedKeys)==JSONSerialization.data(withJSONObject:observed(le32(456)+Array(eh.dropFirst(4))),options:.sortedKeys),"actual_file_id_never_emitted")
    var boundedDiagnostics=HeadDiagnostics()
    for _ in 0..<100 { _ = boundedDiagnostics.observe(Packet(status:1,type:0x1a,id:7,payload:eh),expected:nil,early:true) }
    try check(boundedDiagnostics.samples.count==4 && boundedDiagnostics.count==100 && boundedDiagnostics.omitted==96,"bounded_head_diagnostics")
    try check(boundedDiagnostics.observe(Packet(status:1,type:0x2e,id:1,payload:eh),expected:nil,early:false)==nil && boundedDiagnostics.count==100,"handshake_not_diagnosed")
    // Exercise production dispatch without begin(): no central manager or audio IO.
    let diagnosticPilot=Pilot(try PilotOptions(["scan"]))
    try rejects("dispatch_rejected_head"){try diagnosticPilot.handle(Packet(status:2,type:0x1a,id:7,payload:[0xff]))}
    try check(diagnosticPilot.headDiagnostics.count==1 && !diagnosticPilot.headerSeen && diagnosticPilot.manager==nil,"dispatch_observes_before_envelope_gate_without_hardware")
    let earlyDiagnosticPilot=Pilot(earlyOptions);earlyDiagnosticPilot.earlyRequested=true
    try rejects("dispatch_reserved_head"){try earlyDiagnosticPilot.handle(Packet(status:1,type:0x1a,id:7,payload:errorHead))}
    try check(earlyDiagnosticPilot.headDiagnostics.samples.first?["head_error_code"] as? Int == 7 && earlyDiagnosticPilot.earlyBuffer.head==nil && earlyDiagnosticPilot.fileCrypto==nil,"diagnostic_cannot_bypass_decryption_gate")
    var tail=try active();try tail.frame(seq:0,flags:2);try tail.requestStop();try tail.observeStop();try tail.terminal(123);try tail.verifyRequested();try tail.verifiedIdle(true)
    try tail.frame(seq:1,flags:4)
    try check(tail.lastFlag && tail.fromStartComplete && tail.protocolAudioComplete,"late_tail_after_idle_not_discarded")
    try rejects("tail_duplicate_after_idle"){try tail.frame(seq:1,flags:4)}
    let decoder=try LiveOpus();try rejects("malformed_opus"){_ = try decoder.decode([0])}
    var fresh=try active();try rejects("oversized_sequence"){try fresh.frame(seq:UInt32.max,flags:0)}
    var ack=PilotPolicy();try rejects("unsolicited_start_ack"){try ack.acknowledgeStart()}
    try ack.start(firmwareOK:true,idle:true);try ack.acknowledgeStart();try rejects("duplicate_start_ack"){try ack.acknowledgeStart()}
    for _ in 0..<50 {let pcm=try decoder.decode([0xfc,0xff,0xfe]+Array(repeating:0,count:157));try check(pcm.count==960 && pcm.allSatisfy({$0.isFinite}),"live_exact_frame")}
    var header=le32(42)+le32(UInt32.max)+Array(repeating:UInt8(0),count:79)
    try rejects("head_wrong_id"){_ = try FileHead(header,expected:43)}
    header[86]=1;try rejects("head_error"){_ = try FileHead(header,expected:42)}
    try rejects("decoder_multi_packet"){_ = try decoder.decode([0xff]+Array(repeating:0,count:159))}
    try rejects("crypto_missing_session"){_ = try SessionCrypto().decryptor(FileHead(le32(42)+le32(UInt32.max)+Array(repeating:0,count:79),expected:42))}
    try rejects("crypto_wrong_key_shape"){try SessionCrypto().complete([4])}
    // Corrupt checksum and fragmented valid frame: no framing acceptance of junk.
    var assembly=Assembler();let packet:[UInt8]=[9,255,0,0,1,24,130,11,0,0,174]
    let first=try assembly.feed(Array(packet.prefix(4)));try check(first.isEmpty,"fragment_wait")
    let rest=try assembly.feed(Array(packet.dropFirst(4)));try check(rest.count==1 && rest[0].payload==[0],"fragment_merge")
    var bad=packet;bad[10]=0;_ = try assembly.feed(bad);try check(assembly.corrupt>0,"checksum_reject")
    var verify=StopIdleVerification()
    try rejects("no_retry_before_owned_stop_verification"){try verify.stillRecording(at:1)}
    try verify.begin(at:1);let originalDeadline=verify.deadline
    try verify.stillRecording(at:1.2)
    try check(try !verify.takeDue(at:1.3),"stop_retry_not_busy_loop")
    try check(try verify.takeDue(at:1.36),"stop_retry_due")
    try check(try !verify.takeDue(at:1.37),"only_one_outstanding_info_query")
    try verify.stillRecording(at:1.5)
    try check(verify.deadline==originalDeadline && verify.busyObservations==2,"busy_response_never_extends_deadline")
    verify.complete();try check(try !verify.takeDue(at:2),"idle_cancels_pending_retry")
    try rejects("duplicate_verification_cannot_reset_deadline"){try verify.begin(at:2)}
    var expired=StopIdleVerification();try expired.begin(at:0)
    try rejects("busy_near_deadline_fails"){try expired.stillRecording(at:1.9)}
    var expiredDue=StopIdleVerification();try expiredDue.begin(at:0);try expiredDue.stillRecording(at:0.1)
    try rejects("late_timer_does_not_send_after_deadline"){_ = try expiredDue.takeDue(at:2)}
    var many=StopIdleVerification();try many.begin(at:0)
    for i in 0..<8 {let t=Double(i)*0.2;try many.stillRecording(at:t);_ = try many.takeDue(at:t+0.16)}
    try rejects("stop_info_retry_count_bounded"){try many.stillRecording(at:1.6)}
    // Busy info must leave the policy verifying, so late audio/terminal are accepted.
    var transient=try active();try transient.frame(seq:24,flags:0);try transient.requestStop();try transient.observeStop();try transient.verifyRequested()
    var pending=StopIdleVerification();try pending.begin(at:0);try pending.stillRecording(at:0.1)
    try check(transient.state == .verifying,"busy_info_never_claims_idle")
    try transient.frame(seq:25,flags:4);try transient.terminal(123);try transient.verifiedIdle(true)
    try check(transient.lastFlag && transient.terminalMatched && !transient.protocolAudioComplete,"late_tail_preserved_startup_failure_preserved")
    // Observed early-300 ordering: an invalid zero-ID subscribe can make the device
    // abort the recording before the 1A06 identity arrives. A pre-identity stop
    // notice must stay refusable, and a confirmed idle must never be reported as
    // "stop unconfirmed" (the old fail() suffix did exactly that in that log).
    var preFile=PilotPolicy();try preFile.start(firmwareOK:true,idle:true);try preFile.acknowledgeStart()
    try rejects("external_stop_before_identity_not_assumable"){try preFile.observeStop()}
    var order=try active();try order.frame(seq:0,flags:2);try order.frame(seq:1,flags:0)
    try order.terminal(123)
    try order.observeStop()
    try order.verifyRequested();try order.frame(seq:2,flags:4);try order.verifiedIdle(true)
    try check(order.protocolAudioComplete,"terminal_before_stop_notice_still_completes")
    try check(Pilot.failureRoute(ownsStart:true,hasFile:false,stopSent:false,state:.starting) == .awaitNewSession,"route_early300_awaits_new_session")
    try check(Pilot.failureRoute(ownsStart:false,hasFile:true,stopSent:true,state:.ended) == .confirmedStop,"route_confirmed_stop_never_prompts_device_check")
    try check(Pilot.failureRoute(ownsStart:false,hasFile:true,stopSent:false,state:.ended) == .confirmedStop,"route_external_stop_confirmed_after_idle")
    try check(Pilot.failureRoute(ownsStart:false,hasFile:true,stopSent:true,state:.verifying) == .stopUnconfirmed,"route_stop_sent_but_unconfirmed_prompts_check")
    try check(Pilot.failureRoute(ownsStart:false,hasFile:true,stopSent:false,state:.verifying) == .checkIndicator,"route_no_stop_sent_prompts_indicator")
    try check(Pilot.failureRoute(ownsStart:true,hasFile:true,stopSent:false,state:.streaming) == .requestStop,"route_owned_file_not_stopped_sends_stop")
    // Defensive idempotence only: production handlers clear stopAt synchronously
    // (action==0 sets stopAt=nil; requestStop's success path too) and all callbacks
    // plus tick run on the main queue, so the timer cannot fire after an observed
    // stop. These two checks guard that invariant, they do not claim a reachable bug.
    let stopRace=Pilot(try PilotOptions(["scan"]))
    stopRace.policy=try active();try stopRace.policy.requestStop();try stopRace.policy.observeStop();try stopRace.policy.verifyRequested();try stopRace.policy.verifiedIdle(true)
    stopRace.stopAt=stopRace.now
    stopRace.requestStop()
    try check(!stopRace.stopSent && !stopRace.finished && stopRace.stopAt==nil,"stop_request_idempotent_after_confirmed_stop_defensive")
    var external=try active();try external.frame(seq:24,flags:0);try external.observeStop()
    let externalPilot=Pilot(try PilotOptions(["scan"]));externalPilot.policy=external;externalPilot.stopAt=externalPilot.now
    externalPilot.requestStop()
    try check(!externalPilot.stopSent && external.state == .stopping && external.stopObserved,"external_stop_preserved_without_second_stop_defensive")
    // Reachable variant through the real fail() chain (not the timer): an externally
    // observed stop followed by any failure must not throw a second stop into the
    // stopping device (old code finished with stop_send_failed and exit(2) here,
    // killing the pending verification), and the already-issued info reply must
    // still be allowed to complete cleanup.
    var midVerify=try active();try midVerify.frame(seq:24,flags:0);try midVerify.observeStop();try midVerify.verifyRequested()
    let midPilot=Pilot(try PilotOptions(["scan"]));midPilot.policy=midVerify;midPilot.phase="verify"
    try midPilot.stopVerification.begin(at:midPilot.now)
    midPilot.fail("late_packet_error")
    try check(midPilot.firstFailure=="late_packet_error" && !midPilot.finished && !midPilot.stopSent && midVerify.state == .verifying,"fail_after_external_stop_never_second_stops_or_finishes")
    var idleBody=[UInt8](repeating:0,count:56)
    idleBody.replaceSubrange(3..<8,with:Array("04.92".utf8));idleBody.replaceSubrange(33..<38,with:Array("1.2.2".utf8));idleBody.replaceSubrange(51..<56,with:Array("03.06".utf8));idleBody[50]=0
    try midPilot.handle(Packet(status:1,type:1,id:1,payload:idleBody))
    try check(midPilot.policy.state == .ended && midPilot.idleVerifiedAt != nil && !midPilot.finished,"pending_idle_reply_still_completes_after_failure")
    let busyPilot=Pilot(try PilotOptions(["scan"]))
    busyPilot.policy=try active();try busyPilot.policy.requestStop();try busyPilot.policy.observeStop();try busyPilot.policy.verifyRequested()
    busyPilot.phase="verify";try busyPilot.stopVerification.begin(at:busyPilot.now)
    var infoBody=[UInt8](repeating:0,count:56)
    infoBody.replaceSubrange(3..<8,with:Array("04.92".utf8));infoBody.replaceSubrange(33..<38,with:Array("1.2.2".utf8));infoBody.replaceSubrange(51..<56,with:Array("03.06".utf8));infoBody[50]=1
    try busyPilot.handle(Packet(status:1,type:1,id:1,payload:infoBody))
    try check(busyPilot.policy.state == .verifying && busyPilot.idleVerifiedAt==nil && busyPilot.stopVerification.busyObservations==1,"production_busy_info_keeps_receiving_tail")
    infoBody[50]=0;try busyPilot.handle(Packet(status:1,type:1,id:1,payload:infoBody))
    try check(busyPilot.policy.state == .ended && busyPilot.stopVerification.retryAt==nil,"production_idle_info_completes_verification")
    let testArgs=["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session","--ready-speech-test"]
    let speechOptions=try PilotOptions(testArgs)
    try check(speechOptions.speechTest && speechOptions.capturePath==nil,"speech_default_no_retention")
    try rejects("capture_requires_speech_test"){_ = try PilotOptions(Array(testArgs.dropLast())+["--capture-wav","/tmp/test.wav"])}
    try rejects("speech_no_early"){_ = try PilotOptions(testArgs+["--early-live"])}
    try rejects("speech_no_output"){_ = try PilotOptions(testArgs+["--output-uid","BlackHole2ch_UID"])}
    try rejects("speech_no_relative_capture"){_ = try PilotOptions(testArgs+["--capture-wav","relative.wav"])}
    try rejects("speech_duplicate_capture"){_ = try PilotOptions(testArgs+["--capture-wav","/tmp/a.wav","--capture-wav","/tmp/b.wav"])}
    var trial=SpeechTrial()
    var terminalBeforeReady=try active()
    try check(SpeechTrial.mayAnnounce(terminalBeforeReady,stopSent:false),"active_owned_stream_can_be_ready")
    try check(!SpeechTrial.mayAnnounce(terminalBeforeReady,stopSent:true),"sent_stop_prevents_ready")
    try terminalBeforeReady.terminal(123)
    try check(!SpeechTrial.mayAnnounce(terminalBeforeReady,stopSent:false),"terminal_before_first_pcm_prevents_false_ready")
    try check(!trial.decoded(sequence:24,at:1,streaming:false) && trial.readyAt==nil,"not_ready_before_active_stream")
    try check(trial.decoded(sequence:24,at:2,streaming:true),"ready_on_verified_decoded_frame")
    try check(!trial.decoded(sequence:25,at:3,streaming:true) && trial.readyAt==2,"ready_once_no_timer_extension")
    trial.close()
    try check(!trial.decoded(sequence:26,at:4,streaming:true),"cannot_rearm_after_stop")
    var cancelled=SpeechTrial();cancelled.close()
    try check(!cancelled.decoded(sequence:24,at:2,streaming:true),"cancel_before_ready_stays_closed")
    var postReady=try active();try postReady.frame(seq:24,flags:0);try postReady.requestStop();try postReady.observeStop();try postReady.verifyRequested();try postReady.verifiedIdle(true)
    try check(!trial.transportIntact(postReady,failed:false,buffered:0),"idle_alone_not_trial_complete")
    try postReady.frame(seq:25,flags:4);try postReady.terminal(123)
    try check(trial.transportIntact(postReady,failed:false,buffered:0) && !postReady.protocolAudioComplete,"post_ready_does_not_rewrite_startup_failure")
    try check(!trial.transportIntact(postReady,failed:true,buffered:0),"failure_not_hidden_by_tail")
    try check(!trial.transportIntact(postReady,failed:false,buffered:1),"unparsed_tail_not_complete")
    let temp=FileManager.default.temporaryDirectory.appendingPathComponent("bridge-wav-selftest-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false)
    defer {try? FileManager.default.removeItem(at:temp)} // Only this test's own synthetic fixtures.
    let wavPath=temp.appendingPathComponent("synthetic.wav").path
    let wav=try TrialWAV(path:wavPath)
    try rejects("capture_cannot_overwrite"){_ = try TrialWAV(path:wavPath)}
    try rejects("capture_wrong_frame"){try wav.append([0])}
    try rejects("capture_nonfinite"){try wav.append([Float](repeating:.nan,count:960))}
    try wav.append([Float](repeating:1.25,count:960));try wav.finish()
    try check(wav.peakAbs==1.25 && wav.overUnitSamples==960,"source_amplitude_separate_from_output_clipping")
    let bytes=Array(try Data(contentsOf:URL(fileURLWithPath:wavPath)))
    try check(bytes.count==44+960*4 && u32(bytes,40)==3840 && u32(bytes,24)==48000,"wav_header_matches_exact_samples")
    try check(u32(bytes,44)==Float(1.25).bitPattern,"wav_preserves_samples_without_clipping")
    let permissions=try FileManager.default.attributesOfItem(atPath:wavPath)[.posixPermissions] as? NSNumber
    try check(permissions?.intValue==0o600,"capture_private_permissions")
    try rejects("capture_append_after_finalize"){try wav.append([Float](repeating:0,count:960))}
    try rejects("capture_double_finalize"){try wav.finish()}
    let capped=try TrialWAV(path:temp.appendingPathComponent("cap.wav").path)
    for _ in 0..<1500 {try capped.append([Float](repeating:0,count:960))}
    try rejects("capture_bounded_memory"){try capped.append([Float](repeating:0,count:960))}
    try check(capped.samples==TrialWAV.limit,"capture_limit_no_partial_append")
    let chosen=UUID(),other=UUID()
    try check(knownPeripheralIndex(selected:nil,retrieved:[chosen])==nil,"known_connection_requires_explicit_target")
    try check(knownPeripheralIndex(selected:chosen,retrieved:[])==nil,"unknown_identifier_returns_to_scan")
    try check(knownPeripheralIndex(selected:chosen,retrieved:[other])==nil,"known_connection_never_selects_neighbour")
    try check(knownPeripheralIndex(selected:chosen,retrieved:[other,chosen])==1,"known_connection_exact_match_not_first")
    try check(knownPeripheralIndex(selected:chosen,retrieved:[chosen,chosen])==nil,"ambiguous_cached_candidate_not_selected")
    try check(!speechOptions.connectKnown,"ordinary_scan_default_preserved")
    try check(try PilotOptions(testArgs+["--connect-known"]).connectKnown,"known_connection_explicit_opt_in")
    try rejects("duplicate_known_connect_rejected"){_ = try PilotOptions(testArgs+["--connect-known","--connect-known"])}
    try rejects("known_connect_not_early_experiment"){_ = try PilotOptions(Array(testArgs.dropLast())+["--connect-known","--early-live"])}
    try rejects("inspect_remains_read_only_unchanged_cli"){_ = try PilotOptions(["inspect","--device",chosen.uuidString,"--connect-known"])}
    var prep=PreparationTiming()
    try check(prep.metrics.isEmpty,"missing_timings_not_reported_as_zero")
    try check(prep.mark(.began,at:1) && prep.mark(.bluetoothReady,at:1.1),"timing_uses_monotonic_observations")
    try check(!prep.mark(.began,at:2) && prep.times[.began]==1,"duplicate_cannot_shorten_total_wait")
    try check(!prep.mark(.connectRequested,at:.nan),"nan_clock_rejected")
    try check(!prep.mark(.connectRequested,at:0.9),"backwards_clock_rejected")
    try check(prep.invalidObservations==2 && prep.times[.connectRequested]==nil,"invalid_timing_remains_unknown")
    try check(prep.mark(.connectRequested,at:2) && prep.mark(.connected,at:3),"direct_connect_timing_without_scan")
    try check(prep.metrics["scan_to_connect_request_s"]==nil && prep.metrics["connect_s"]==1,"direct_connect_does_not_invent_scan_duration")
    try check(prep.metrics["tool_begin_to_first_pcm_s"]==nil,"failed_start_does_not_invent_ready")
    try check(prep.mark(.startRequested,at:4) && prep.mark(.firstDecoded,at:5),"record_observed_first_pcm")
    try check(prep.metrics["tool_begin_to_first_pcm_s"]==4 && prep.metrics["start_to_first_pcm_s"]==1,"total_wait_not_replaced_by_command_wait")
    try check(prep.metrics["tool_begin_to_ready_presented_s"]==nil,"decoded_does_not_invent_ui_ready")
    try check(prep.mark(.readyPresented,at:5.01) && prep.metrics["tool_begin_to_ready_presented_s"]!>4,"ui_time_keeps_total_wait")
    var boundedPrep=PreparationTiming()
    for stage in PreparationTiming.Stage.allCases {boundedPrep.mark(stage,at:1)}
    for _ in 0..<10000 {boundedPrep.mark(.began,at:2)}
    try check(boundedPrep.times.count==PreparationTiming.Stage.allCases.count,"telemetry_storage_bounded_under_duplicate_events")
    func drain(_ elapsed:Double,_ quiet:Double,_ last:Bool=true,_ terminal:Bool=true,_ pending:Int=0,_ unparsed:Int=0)->TailDrainDecision {
        tailDrainDecision(elapsed:elapsed,quiet:quiet,pending:pending,lastFlag:last,terminalMatched:terminal,unparsed:unparsed)
    }
    try check(drain(0.4,0.3,false) == .wait,"missing_last_flag_gets_remaining_drain_budget")
    try check(drain(0.4,0.3,true,false) == .wait,"missing_terminal_gets_remaining_drain_budget")
    try check(drain(0.4,0.3) == .finish,"complete_tail_keeps_fast_finish")
    try check(drain(0.34,0.3) == .wait,"drain_minimum_not_shortened")
    try check(drain(0.4,0.24) == .wait,"drain_quiet_period_not_shortened")
    try check(drain(0.8,0.3) == .finish,"late_tail_can_finish_within_original_budget")
    try check(drain(1,0.3,false) == .timeout,"missing_tail_still_fails_at_original_deadline")
    try check(drain(1,0.1,false,false) == .timeout,"ongoing_activity_does_not_extend_drain_deadline")
    try check(drain(0.4,0.3,true,true,1) == .wait,"output_backlog_not_drained")
    try check(drain(1,0.3,true,true,1) == .timeout,"output_backlog_remains_bounded")
    try check(drain(0.4,0.3,true,true,0,1) == .wait,"partial_transport_not_complete")
    try check(drain(.nan,0.3) == .timeout,"invalid_clock_cannot_pass_drain")
    var tailStats=TailTelemetry()
    try check(tailStats.fields(stop:nil,idle:nil,terminal:nil,finish:0)["last_audio_minus_stop_s"]==nil,"tail_unknown_not_zero")
    try check(tailStats.record(sequence:24,flags:0,received:1,stop:nil,idle:nil,terminal:nil),"tail_metadata_accepts_valid_decoded_frame")
    try check(tailStats.record(sequence:25,flags:0,received:2,stop:1.5,idle:nil,terminal:nil),"tail_after_stop_observed")
    try check(tailStats.record(sequence:26,flags:4,received:3,stop:1.5,idle:2.5,terminal:2.7),"tail_after_idle_and_terminal_observed")
    try check(tailStats.afterStop==2 && tailStats.afterIdle==1 && tailStats.afterTerminal==1,"tail_phase_counts_separate")
    let tailFields=tailStats.fields(stop:1.5,idle:2.5,terminal:2.7,finish:3.5)
    try check(tailFields["tail_flag_minus_idle_s"] as? Double == 0.5,"late_tail_timestamp_not_idle_timestamp")
    try check(tailFields["finish_minus_idle_s"] as? Double == 1,"drain_duration_observed")
    try check(!tailStats.record(sequence:26,flags:4,received:3,stop:nil,idle:nil,terminal:nil),"tail_duplicate_not_counted")
    try check(!tailStats.record(sequence:27,flags:0,received:2,stop:nil,idle:nil,terminal:nil),"tail_backwards_clock_not_counted")
    try check(!tailStats.record(sequence:27,flags:0,received:.nan,stop:nil,idle:nil,terminal:nil),"tail_nonfinite_clock_not_counted")
    try check(!tailStats.record(sequence:27,flags:8,received:4,stop:nil,idle:nil,terminal:nil),"tail_unknown_flag_not_counted")
    try check(tailStats.frames==3 && tailStats.invalid==4,"bad_metadata_does_not_change_valid_counts")
    var boundedTail=TailTelemetry()
    for i in 0..<1500 {boundedTail.record(sequence:UInt32(i),flags:0,received:Double(i),stop:1450,idle:1460,terminal:1470)}
    try check(boundedTail.recent.count==32 && boundedTail.recent.first?.sequence==1468,"tail_metadata_ring_is_bounded")
    try check(boundedTail.afterStop==50 && boundedTail.afterIdle==40 && boundedTail.afterTerminal==30,"ring_eviction_preserves_phase_counts")
    try check(boundedTail.lastFlagAt==nil,"terminal_never_invents_tail_flag")
    try check(boundedTail.record(sequence:1500,flags:0,received:1500,stop:nil,idle:nil,terminal:nil),"tail_telemetry_counts_past_short_trial_budget")
    let earlyLast=tailStats.fields(stop:4,idle:4.1,terminal:4.2,finish:5)
    try check(earlyLast["last_audio_minus_stop_s"] as? Double == -1,"tail_before_stop_keeps_negative_delta")
    try check(drain(1.3,0.3) == .timeout,"complete_evidence_after_absolute_budget_is_not_success")
    try check(drain(1.000001,0.3) == .timeout,"just_past_absolute_budget_is_not_success")
    try check(drain(1,0.3) == .finish,"complete_at_exact_budget_boundary_allowed")
    try check(drain(0.999999,0.3) == .finish,"complete_within_budget_still_allowed")
    // Synthetic fixture; no BLE manager, keys from a device, WAV, output, or ASR.
    // Use the SAME reassembly/dispatch/decrypt/decode path as BLE notifications.
    let fixtureCrypto=FileCrypto(key:Array(repeating:0x31,count:32),nonce:Array(repeating:0x42,count:16))
    let fixtureOpus:[UInt8]=[0xfc,0xff,0xfe]+Array(repeating:0,count:157)
    func fixtureWire(_ type:UInt8,_ id:UInt8,_ body:[UInt8])->[UInt8] {
        let size=body.count+10
        var bytes:[UInt8]=[9,255,0,0,1,type,id,UInt8(size&255),UInt8(size>>8)]+body
        bytes.append(bytes.reduce(UInt8(0),{$0 &+ $1}));return bytes
    }
    func fixtureSlice(_ seq:UInt32,_ flags:UInt8,_ opus:[UInt8]?=nil)throws->[UInt8] {
        let encrypted=try fixtureCrypto.decode(opus ?? fixtureOpus,sequence:seq)
        return le32(seq)+[flags]+encrypted+[0]
    }
    func fixturePilot()throws->Pilot {
        let driver=Pilot(try PilotOptions(["scan"]))
        driver.policy=try active()
        for seq in 24...143 {try driver.policy.frame(seq:UInt32(seq),flags:0)}
        try driver.policy.requestStop();try driver.policy.observeStop();try driver.policy.verifyRequested();try driver.policy.verifiedIdle(true)
        driver.stopSent=true;driver.phase="verify";driver.headerSeen=true
        driver.fileCrypto=fixtureCrypto;driver.decoder=try LiveOpus();driver.firstAt=driver.now
        driver.stopSentAt=driver.now;driver.idleVerifiedAt=driver.now
        return driver
    }
    let wireTail=fixtureWire(0x1a,8,try fixtureSlice(144,4))
    let wireTerminal=fixtureWire(0x1a,0x0a,[0,0,0,0,0]+le32(123))
    for wire in [wireTail+wireTerminal,wireTerminal+wireTail] {
        for split in 0...wire.count {
            let driver=try fixturePilot()
            try driver.consumeNotification(Array(wire.prefix(split)))
            try driver.consumeNotification(Array(wire.dropFirst(split)))
            try check(driver.assembly.buffered==0 && driver.policy.last==144 && driver.policy.frames==121 &&
                      driver.policy.lastFlag && driver.policy.terminalMatched && driver.policy.state == .ended &&
                      driver.tailTelemetry.frames==1 && driver.tailTelemetry.invalid==0 &&
                      driver.tailTelemetry.lastFlagAt != nil && !driver.policy.protocolAudioComplete,
                      "tail_terminal_all_split_boundaries_keep_tail_and_startup_failure")
        }
    }
    let bytewise=try fixturePilot()
    for byte in wireTail+wireTerminal {try bytewise.consumeNotification([byte])}
    try check(bytewise.policy.lastFlag && bytewise.policy.terminalMatched && bytewise.assembly.buffered==0,"bytewise_tail_and_terminal_not_lost")
    let multi=try fixturePilot()
    try multi.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(144,0)+fixtureSlice(145,4))+wireTerminal)
    try check(multi.policy.frames==122 && multi.policy.last==145 && multi.policy.lastFlag && multi.tailTelemetry.frames==2,"tail_in_final_slot_of_multi_frame_packet")
    let concatenated=try fixturePilot()
    try concatenated.consumeNotification(wireTail+wireTerminal)
    try check(concatenated.policy.lastFlag && concatenated.policy.terminalMatched && concatenated.assembly.buffered==0,"tail_and_terminal_concatenated_single_notification")
    // Post-failure / awaiting-stop audio is discarded by policy but must be
    // COUNTED, never silently dropped: the early zero-ID exclusion once leaned
    // on "no audio followed" while this branch returned without a trace.
    let failedDiscard=try fixturePilot()
    failedDiscard.exitStatus=2
    try failedDiscard.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(144,0)+fixtureSlice(145,4)))
    try check(failedDiscard.postFailureAudioNotifications==1 && failedDiscard.postFailureAudioFrames==2 && failedDiscard.policy.frames==120 && !failedDiscard.policy.lastFlag && failedDiscard.assembly.buffered==0 && failedDiscard.tailTelemetry.frames==0,"post_failure_audio_counted_not_processed")
    let awaitingDiscard=try fixturePilot()
    awaitingDiscard.awaitingOwnedStop=true
    try awaitingDiscard.consumeNotification(wireTail)
    try check(awaitingDiscard.postFailureAudioNotifications==1 && awaitingDiscard.postFailureAudioFrames==1 && awaitingDiscard.policy.frames==120,"awaiting_stop_audio_counted_not_processed")
    try check(failedDiscard.decoder != nil && failedDiscard.trialWAV == nil,"discard_path_never_touches_capture")
    // 1B0E trailer parser: pure and deliberately disconnected from every Request
    // encoding and dispatch path. Fixtures follow the pinned upstream layout
    // (count u16 + entries x12B + trailer 8B); everything malformed is rejected,
    // and even a fresh candidate never claims session identity or capture rights.
    func listPayload(entries:[[UInt8]], trailer:[UInt8]?=nil) -> [UInt8] {
        var bytes=[UInt8(entries.count&255),UInt8(entries.count>>8)]
        for e in entries {bytes += e}
        if let t=trailer {bytes += t}
        return bytes
    }
    func entry(_ id:UInt32,end:UInt32=0,duration:UInt32) -> [UInt8] {le32(id)+le32(end)+le32(duration)}
    func trailer(_ id:UInt32,duration:UInt32) -> [UInt8] {le32(id)+le32(duration)}
    try check(TransportListSample.parse([],baseline:nil).trailer == .invalid(reason:"truncated_header"),"list_rejects_empty")
    var short=listPayload(entries:[entry(5,duration:100)]);short.removeLast()
    try check(TransportListSample.parse(short,baseline:nil).trailer == .invalid(reason:"count_exceeds_payload"),"list_rejects_truncated_entries")
    try check(TransportListSample.parse(listPayload(entries:[]),baseline:nil).trailer == .absent,"list_exact_fit_no_trailer_absent")
    try check(TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(1234,duration:1060)),baseline:1233).trailer == .newerThanBaseline(fileId:1234,rawDuration:1060),"list_fresh_candidate_vs_baseline")
    try check(TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(0,duration:1060)),baseline:1233).trailer == .invalid(reason:"reserved_trailer_id") && TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(UInt32.max,duration:1060)),baseline:1233).trailer == .invalid(reason:"reserved_trailer_id"),"list_rejects_reserved_trailer_ids")
    try check(TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(1233,duration:1060)),baseline:1233).trailer == .invalid(reason:"not_newer_than_baseline"),"list_rejects_stale_trailer")
    try check(TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(1234,duration:1060)),baseline:nil).trailer == .unassessed(fileId:1234,rawDuration:1060),"list_without_baseline_stays_unassessed")
    try check(TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(1234,duration:1060))+[0],baseline:1233).trailer == .invalid(reason:"trailing_length_unknown"),"list_rejects_extra_trailing_bytes")
    try check(TransportListSample.parse(Array(listPayload(entries:[entry(5,duration:100)],trailer:trailer(1234,duration:1060)).dropLast(2)),baseline:1233).trailer == .invalid(reason:"truncated_trailer"),"list_rejects_partial_trailer")
    try check(TransportListSample.parse(listPayload(entries:[entry(5,duration:100)],trailer:trailer(1234,duration:1061)),baseline:1233).trailer == .newerThanBaseline(fileId:1234,rawDuration:1061),"list_preserves_unverified_trailer_duration_units")
    var big=listPayload(entries:[]);big[0]=65;big[1]=0
    try check(TransportListSample.parse(big,baseline:nil).trailer == .invalid(reason:"entry_count_layout_unknown"),"list_rejects_unknown_count_scale")
    let mixed=TransportListSample.parse(listPayload(entries:[entry(0,duration:0),entry(7,duration:40)],trailer:trailer(7,duration:1060)),baseline:6)
    try check(mixed.listedEntries==1 && mixed.firstListedFileId==7 && mixed.reportedCount==2 && mixed.trailer == .newerThanBaseline(fileId:7,rawDuration:1060),"list_entry_and_trailer_kept_distinct")
    let reparse=TransportListSample.parse(listPayload(entries:[entry(7,duration:40)],trailer:trailer(7,duration:1060)),baseline:6)
    try check(reparse == mixed || (reparse.listedEntries==mixed.listedEntries && reparse.trailer==mixed.trailer),"list_parser_is_pure")
    try check(TransportListSample.parse(listPayload(entries:[],trailer:trailer(1232,duration:0)),baseline:1233).trailer == .invalid(reason:"not_newer_than_baseline"),"list_rejects_older_trailer_identity")
    try check(TransportListSample.parse(listPayload(entries:[],trailer:trailer(1234,duration:UInt32.max)),baseline:nil).trailer == .unassessed(fileId:1234,rawDuration:UInt32.max),"list_raw_duration_never_proves_current_session")
    let partial=try fixturePilot()
    try partial.consumeNotification(Array(wireTail.dropLast()))
    try check(!partial.policy.lastFlag && partial.assembly.buffered>0 && partial.tailTelemetry.frames==0,"partial_tail_never_decoded_before_checksum")
    try partial.consumeNotification([wireTail.last!])
    try check(partial.policy.lastFlag && partial.tailTelemetry.frames==1,"last_checksum_byte_completes_tail")
    let corruptDriver=try fixturePilot();var corruptTail=wireTail;corruptTail[corruptTail.count-1] ^= 1
    try rejects("bad_tail_checksum_not_dispatched"){try corruptDriver.consumeNotification(corruptTail+wireTerminal)}
    try check(corruptDriver.policy.frames==120 && !corruptDriver.policy.lastFlag && !corruptDriver.policy.terminalMatched,"mixed_corrupt_notification_cannot_partially_pass")
    let wrongEnd=try fixturePilot()
    try rejects("wrong_end_identity_rejected_before_following_tail"){try wrongEnd.consumeNotification(fixtureWire(0x1a,0x0a,[0,0,0,0,0]+le32(999))+wireTail)}
    try check(wrongEnd.policy.frames==120 && wrongEnd.tailTelemetry.frames==0,"wrong_session_never_reaches_decoder")
    let missingEndFlag=try fixturePilot()
    try missingEndFlag.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(144,0))+wireTerminal)
    try check(!missingEndFlag.policy.lastFlag && missingEndFlag.policy.terminalMatched && missingEndFlag.tailTelemetry.lastFlagAt==nil,"end_notification_does_not_synthesize_missing_flag")
    let repeated=try fixturePilot();try repeated.consumeNotification(wireTail)
    try rejects("wire_duplicate_tail_rejected"){try repeated.consumeNotification(wireTail)}
    let gapDriver=try fixturePilot()
    try rejects("wire_gap_rejected_before_decode"){try gapDriver.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(145,4)))}
    try check(gapDriver.tailTelemetry.frames==0 && !gapDriver.policy.lastFlag,"wire_gap_not_accepted_by_telemetry")
    let invalidAudio=try fixturePilot()
    try rejects("invalid_opus_in_tail_rejected"){try invalidAudio.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(144,4,[0xff]+Array(repeating:0,count:159))))}
    try check(invalidAudio.tailTelemetry.frames==0,"undecodable_tail_not_counted_as_decoded")

    // Same-current-recording comparison is optional and never changes live gates.
    let comparisonBase=["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session"]
    let comparisonArgs=comparisonBase+["--ready-speech-test","--capture-wav","/tmp/live.wav","--compare-device-wav","/tmp/file.wav"]
    try check(try PilotOptions(comparisonArgs).comparisonPath=="/tmp/file.wav","explicit_comparison_paths")
    try check(try PilotOptions(comparisonBase).comparisonPath==nil,"comparison_off_by_default")
    for args in [comparisonBase+["--compare-device-wav","/tmp/file.wav"],
                 comparisonArgs+["--early-live"],comparisonArgs+["--output-uid","BlackHole2ch_UID"],
                 comparisonArgs+["--compare-device-wav","/tmp/other.wav"],
                 comparisonBase+["--ready-speech-test","--capture-wav","/tmp/live.wav","--compare-device-wav","/tmp/live.wav"]] {
        try rejects("comparison_cli_isolated_explicit_unique"){_ = try PilotOptions(args)}
    }
    func comparedLive(tail:Bool=false)throws->(PilotPolicy,DeviceComparison) {
        var policy=try active(),comparison=DeviceComparison()
        for seq:UInt32 in [24,25] {
            let flags:UInt8=tail && seq==25 ? 4:0
            try policy.frame(seq:seq,flags:flags)
            try comparison.observeLive(sequence:seq,flags:flags,opus:fixtureOpus)
        }
        try policy.requestStop();try policy.observeStop();try policy.terminal(123)
        try policy.verifyRequested();try policy.verifiedIdle(true)
        return (policy,comparison)
    }
    func comparisonHead(_ count:Int,id:UInt32=123)->[UInt8] {le32(id)+le32(UInt32(count*166))+Array(repeating:0,count:79)}
    func comparisonReceiving(_ count:Int=27)throws->DeviceComparison {
        let (policy,saved)=try comparedLive();var c=saved
        let id=try c.begin(policy,authorized:true,failed:false,buffered:0)
        try c.authorizeRequest(id);_ = try c.acceptHead(comparisonHead(count));return c
    }
    let (missingPolicy,missingComparison)=try comparedLive()
    for (authorized,failed,buffered) in [(false,false,0),(true,true,0),(true,false,1)] {
        var c=missingComparison
        try rejects("comparison_requires_explicit_clean_session"){_ = try c.begin(missingPolicy,authorized:authorized,failed:failed,buffered:buffered)}
    }
    var c=missingComparison
    let currentID=try c.begin(missingPolicy,authorized:true,failed:false,buffered:0)
    try check(currentID==123 && !missingPolicy.lastFlag && !missingPolicy.protocolAudioComplete,"missing_live_tail_allows_diagnosis_not_acceptance")
    try rejects("cannot_read_without_consumed_capability"){_ = try c.acceptHead(comparisonHead(27))}
    try rejects("cannot_request_arbitrary_id"){try c.authorizeRequest(999)}
    try c.authorizeRequest(currentID)
    try rejects("no_second_file_request"){try c.authorizeRequest(currentID)}
    try rejects("no_second_begin"){_ = try c.begin(missingPolicy,authorized:true,failed:false,buffered:0)}
    try rejects("wrong_file_finite_head"){_ = try c.acceptHead(comparisonHead(27,id:999))}
    for size:UInt32 in [0,UInt32.max,1,165,167,166*25,166*1001] {
        var candidate=c
        try rejects("finite_file_size_checked"){_ = try candidate.acceptHead(le32(123)+le32(size)+Array(repeating:0,count:79))}
    }
    var errorComparisonHead=comparisonHead(27);errorComparisonHead[86]=7
    try rejects("comparison_head_error"){_ = try c.acceptHead(errorComparisonHead)}
    try rejects("terminal_before_matching_file_head"){try c.acceptTerminal(123)}
    _ = try c.acceptHead(comparisonHead(27))
    try rejects("duplicate_finite_head"){_ = try c.acceptHead(comparisonHead(27))}
    try rejects("file_end_wrong_id"){try c.acceptTerminal(999)}
    try c.acceptTerminal(123)
    try rejects("duplicate_file_end"){try c.acceptTerminal(123)}
    try check(!c.readyToComplete,"terminal_does_not_prove_file_complete")
    try check(c.fields["live_tail_outcome"]==nil,"tail_outcome_only_after_complete")
    for seq in 0..<27 {try c.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:(seq==26 ? 4:0),opus:fixtureOpus)}
    try rejects("file_sample_count_must_match"){try c.complete(buffered:0,samples:26*960)}
    try rejects("file_pending_fragment_not_complete"){try c.complete(buffered:1,samples:27*960)}
    try c.complete(buffered:0,samples:27*960)
    try check(c.fields["suffix_frames_absent_from_live"] as? Int == 1 && c.fields["prefix_frames_absent_from_live"] as? Int == 24 && c.byteMismatches==0,"diagnose_missing_real_tail_frame")
    try check(c.fields["live_tail_outcome"] as? String == "tail_frames_absent_from_live","tail_frames_absent_classified")
    try check(!missingPolicy.lastFlag && !missingPolicy.protocolAudioComplete,"comparison_never_repairs_live_policy")
    try rejects("file_audio_after_completed"){try c.acceptFrame(sequence:27,flags:4,opus:fixtureOpus)}
    var flagOnly=try comparisonReceiving(26)
    for seq in 0..<26 {try flagOnly.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:(seq==25 ? 4:0),opus:fixtureOpus)}
    try flagOnly.acceptTerminal(123);try flagOnly.complete(buffered:0,samples:26*960)
    try check(flagOnly.flagDifferences==1 && flagOnly.byteMismatches==0 && flagOnly.fields["suffix_frames_absent_from_live"] as? Int == 0,"missing_flag_distinct_from_missing_opus")
    try check(flagOnly.fields["live_tail_outcome"] as? String == "tail_marker_flag_missing_in_live_only","tail_flag_only_classified")
    var intact=try comparedLive(tail:true)
    let intactID=try intact.1.begin(intact.0,authorized:true,failed:false,buffered:0)
    try intact.1.authorizeRequest(intactID);_ = try intact.1.acceptHead(comparisonHead(26))
    for seq in 0..<26 {try intact.1.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:(seq==25 ? 4:0),opus:fixtureOpus)}
    try intact.1.acceptTerminal(123);try intact.1.complete(buffered:0,samples:26*960)
    try check(intact.1.fields["live_tail_outcome"] as? String == "tail_frames_and_marker_intact" && intact.1.fields["suffix_frames_absent_from_live"] as? Int == 0,"tail_intact_classified")
    var finalBytes=try comparedLive(tail:true)
    let finalID=try finalBytes.1.begin(finalBytes.0,authorized:true,failed:false,buffered:0)
    try finalBytes.1.authorizeRequest(finalID);_ = try finalBytes.1.acceptHead(comparisonHead(26))
    for seq in 0..<26 {
        var bytes=fixtureOpus;if seq==25{bytes[100]=1}
        try finalBytes.1.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:(seq==25 ? 4:0),opus:bytes)
    }
    try finalBytes.1.acceptTerminal(123);try finalBytes.1.complete(buffered:0,samples:26*960)
    try check(finalBytes.1.byteMismatches==1 && finalBytes.1.otherFlagDifferences==0 && finalBytes.1.fields["live_tail_outcome"] as? String == "overlap_mismatch_tail_outcome_unproven","final_flags_match_bytes_differ_unproven")
    var multiFlag=try comparedLive()
    let multiID=try multiFlag.1.begin(multiFlag.0,authorized:true,failed:false,buffered:0)
    try multiFlag.1.authorizeRequest(multiID);_ = try multiFlag.1.acceptHead(comparisonHead(26))
    for seq in 0..<26 {try multiFlag.1.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:(seq==24 ? 1:(seq==25 ? 4:0)),opus:fixtureOpus)}
    try multiFlag.1.acceptTerminal(123);try multiFlag.1.complete(buffered:0,samples:26*960)
    try check(multiFlag.1.flagDifferences==2 && multiFlag.1.otherFlagDifferences==1 && multiFlag.1.fields["live_tail_outcome"] as? String == "overlap_mismatch_tail_outcome_unproven","nonfinal_flag_difference_unproven")
    var mismatch=try comparisonReceiving()
    for seq in 0..<27 {
        var bytes=fixtureOpus;if seq==24{bytes[100]=1}
        try mismatch.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:(seq==26 ? 4:0),opus:bytes)
    }
    try mismatch.acceptTerminal(123);try mismatch.complete(buffered:0,samples:27*960)
    try check(mismatch.byteMismatches==1 && mismatch.otherFlagDifferences==0 && mismatch.fields["all_live_opus_bytes_equal_file"] as? Bool == false && mismatch.fields["live_tail_outcome"] as? String == "overlap_mismatch_tail_outcome_unproven","byte_mismatch_reported_not_hidden")
    for (seq,flags) in [(1,UInt8(0)),(0,0),(0,6),(0,10)] {
        var bad=try comparisonReceiving()
        try rejects("bad_file_first_frame"){try bad.acceptFrame(sequence:UInt32(seq),flags:flags,opus:fixtureOpus)}
    }
    for seq:UInt32 in [0,2] {
        var bad=try comparisonReceiving();try bad.acceptFrame(sequence:0,flags:2,opus:fixtureOpus)
        try rejects("file_duplicate_or_gap"){try bad.acceptFrame(sequence:seq,flags:0,opus:fixtureOpus)}
    }
    var earlyTail=try comparisonReceiving();try earlyTail.acceptFrame(sequence:0,flags:2,opus:fixtureOpus)
    try rejects("file_premature_last_flag"){try earlyTail.acceptFrame(sequence:1,flags:4,opus:fixtureOpus)}
    var noFlag=try comparisonReceiving()
    for seq in 0..<26 {try noFlag.acceptFrame(sequence:UInt32(seq),flags:seq==0 ? 2:0,opus:fixtureOpus)}
    try rejects("file_final_missing_flag"){try noFlag.acceptFrame(sequence:26,flags:0,opus:fixtureOpus)}
    var empty=DeviceComparison()
    try rejects("no_live_overlap_no_download"){_ = try empty.begin(missingPolicy,authorized:true,failed:false,buffered:0)}
    var running=try active();try running.frame(seq:24,flags:0);try running.frame(seq:25,flags:0)
    var unsafe=missingComparison
    try rejects("running_device_not_read"){_ = try unsafe.begin(running,authorized:true,failed:false,buffered:0)}
    var duplicateLive=missingComparison
    try rejects("duplicate_live_hash_rejected"){try duplicateLive.observeLive(sequence:25,flags:0,opus:fixtureOpus)}
    try rejects("late_live_hash_rejected"){try c.observeLive(sequence:26,flags:0,opus:fixtureOpus)}
    // Actual callback dispatch/decrypt/decode with independent decoder and WAV.
    let cmpDriver=Pilot(try PilotOptions(comparisonArgs))
    cmpDriver.policy=missingPolicy;cmpDriver.comparison=try comparisonReceiving()
    cmpDriver.comparisonDeadline=cmpDriver.now+15;cmpDriver.comparisonCrypto=fixtureCrypto
    cmpDriver.comparisonDecoder=try LiveOpus();cmpDriver.comparisonWAV=try TrialWAV(path:temp.appendingPathComponent("comparison.wav").path)
    cmpDriver.firstAt=cmpDriver.now
    var fileWire:[UInt8]=[]
    for seq in 0..<27 {fileWire += fixtureWire(0x1a,8,try fixtureSlice(UInt32(seq),seq==0 ? 2:(seq==26 ? 4:0)))}
    for offset in stride(from:0,to:fileWire.count,by:37) {try cmpDriver.consumeNotification(Array(fileWire[offset..<min(fileWire.count,offset+37)]))}
    try cmpDriver.consumeNotification(wireTerminal)
    try check(cmpDriver.comparison.readyToComplete && cmpDriver.comparisonWAV?.samples==27*960 && cmpDriver.policy.frames==2 && !cmpDriver.policy.lastFlag,"comparison_wire_path_does_not_modify_live")
    try cmpDriver.comparison.complete(buffered:cmpDriver.assembly.buffered,samples:cmpDriver.comparisonWAV!.samples)
    try cmpDriver.comparisonWAV!.finish()
    try cmpDriver.handleComparison(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try check(cmpDriver.policy.state == .ended,"comparison_duplicate_stop_idempotent")
    try rejects("comparison_rejects_external_start"){try cmpDriver.handleComparison(Packet(status:1,type:0x18,id:0x82,payload:[1]))}
    try rejects("comparison_new_session_refused"){try cmpDriver.handleComparison(Packet(status:1,type:0x1a,id:6,payload:le32(999)))}
    cmpDriver.comparisonDeadline=cmpDriver.now-1
    try rejects("comparison_deadline_not_extended"){try cmpDriver.handleComparison(Packet(status:1,type:0x18,id:0x82,payload:[0]))}
    // ---- Opt-in pause-first stop probe (default off; unvalidated on hardware) ----
    let pauseBase=["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session"]
    try check(try PilotOptions(pauseBase).pauseBeforeStopMs==nil,"pause_probe_off_by_default")
    try check(try PilotOptions(pauseBase+["--pause-before-stop-ms","100"]).pauseBeforeStopMs==100,"pause_probe_min_bound")
    try check(try PilotOptions(pauseBase+["--pause-before-stop-ms","500"]).pauseBeforeStopMs==500,"pause_probe_max_bound")
    for bad in ["99","501","0","1000","-100","abc","100ms","3.5"," 200"] {
        try rejects("pause_probe_window_bounded"){_ = try PilotOptions(pauseBase+["--pause-before-stop-ms",bad])}
    }
    try rejects("pause_probe_duplicate_rejected"){_ = try PilotOptions(pauseBase+["--pause-before-stop-ms","200","--pause-before-stop-ms","200"])}
    try rejects("pause_probe_not_with_early_live"){_ = try PilotOptions(pauseBase+["--pause-before-stop-ms","200","--early-live"])}
    try rejects("pause_probe_not_with_system_output"){_ = try PilotOptions(pauseBase+["--pause-before-stop-ms","200","--output-uid","BlackHole2ch_UID"])}
    try check(try PilotOptions(pauseBase+["--output-uid","BlackHole2ch_UID"]).output=="BlackHole2ch_UID","system_output_still_allowed_without_probe")
    try rejects("pause_probe_not_inspect"){_ = try PilotOptions(["inspect","--device",UUID().uuidString,"--pause-before-stop-ms","200"])}
    let pauseCompare=pauseBase+["--ready-speech-test","--capture-wav","/tmp/pause-live.wav","--compare-device-wav","/tmp/pause-device.wav","--pause-before-stop-ms","200"]
    try check(try PilotOptions(pauseCompare).comparisonPath=="/tmp/pause-device.wav","pause_probe_allowed_with_comparison_trial")
    let pauseEncoded=try Request.pauseOwned.encoded()
    try check(pauseEncoded==[8,238,0,0,0,24,130,11,0,2,157],"pause_command_bytes_18_82_02")
    var seq=PauseStopSequencer()
    try check(seq.begin(at:0) && !seq.begin(at:1),"sequencer_single_begin")
    seq.pauseWritten()
    try check(!seq.acknowledge(at:2.01,windowMs:300),"sequencer_ack_after_timeout_rejected")
    try check(seq.poll(at:2.01) == .sendFinalStop("pause_ack_timeout"),"sequencer_timeout_requests_final_stop")
    seq.finalStopWritten()
    try check(seq.outcome == .finalStopSent && !seq.active && seq.poll(at:3) == .none,"sequencer_finished_after_timeout_stop")
    var seq2=PauseStopSequencer();_ = seq2.begin(at:0);seq2.pauseWritten()
    try check(!seq2.acknowledge(at:0.5,windowMs:99),"sequencer_window_below_min_rejected")
    try check(seq2.acknowledge(at:0.5,windowMs:300),"sequencer_valid_ack")
    try check(seq2.poll(at:0.79) == .none && seq2.poll(at:0.81) == .sendFinalStop("pause_window_elapsed"),"sequencer_window_boundary")
    try check(seq2.noteDuplicateAck() && seq2.duplicateAcks==1,"sequencer_duplicate_ack_counted")
    var seq3=PauseStopSequencer();_ = seq3.begin(at:0);seq3.pauseWritten()
    try check(!seq3.acknowledge(at:.nan,windowMs:300) && !seq3.acknowledge(at:0.1,windowMs:501),"sequencer_bad_inputs_rejected")
    seq3.abort();try check(seq3.outcome == .aborted && !seq3.active,"sequencer_abort_state")
    var seq4=PauseStopSequencer();_ = seq4.begin(at:0);seq4.pauseWritten()
    try check(!seq4.acknowledge(at:2.0,windowMs:300),"sequencer_ack_at_exact_timeout_rejected")
    try check(seq4.poll(at:2.0) == .sendFinalStop("pause_ack_timeout"),"sequencer_poll_at_exact_timeout_requests_stop")
    var seq5=PauseStopSequencer();_ = seq5.begin(at:0);seq5.pauseWritten()
    try check(seq5.acknowledge(at:1.999,windowMs:300),"sequencer_ack_just_before_timeout_accepted")
    func pausePilot(_ ms:String="300")throws->(Pilot,CommandLog) {
        let log=CommandLog()
        let pilot=Pilot(try PilotOptions(["live-pilot","--device",UUID().uuidString,"--seconds","15","--public-session","--pause-before-stop-ms",ms]))
        pilot.commandSink={r in log.names.append(requestName(r))}
        pilot.policy=try active()
        pilot.phase="streaming";pilot.headerSeen=true;pilot.fileCrypto=fixtureCrypto;pilot.decoder=try LiveOpus()
        pilot.firstAt=pilot.now;pilot.deadline=pilot.now+10;pilot.hardDeadline=pilot.now+60
        return (pilot,log)
    }
    var clock=100.0
    let (pp,plog)=try pausePilot()
    pp.nowOverride={clock};pp.stopAt=clock;pp.tick()
    try check(plog.names==["pause"] && !pp.stopSent && pp.pauseStop.awaitingAck && pp.policy.state == .streaming,"pause_first_sends_pause_not_stop")
    try pp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try check(pp.pauseStop.holding && !pp.stopSent && !pp.policy.stopObserved && pp.policy.state == .streaming,"pause_ack_never_labeled_stopped")
    try pp.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(24,0)+fixtureSlice(25,4)))
    try check(pp.policy.frames==2 && pp.pauseFrames==2 && pp.pauseFirstSeq==24 && pp.pauseLastSeq==25,"late_slices_during_pause_observed")
    clock+=0.2;pp.tick()
    try check(plog.names==["pause"] && !pp.stopSent,"final_stop_waits_for_bounded_window")
    clock+=0.11;pp.tick()
    try check(plog.names==["pause","stop"] && pp.stopSent && pp.policy.state == .stopping && pp.pauseStop.outcome == .finalStopSent,"window_elapsed_sends_final_stop")
    try pp.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try check(pp.policy.stopObserved && plog.names==["pause","stop","info"],"stop_after_pause_enters_existing_verification")
    try pp.handle(Packet(status:1,type:1,id:1,payload:infoBody))
    try check(pp.policy.state == .ended && pp.idleVerifiedAt != nil && !pp.policy.protocolAudioComplete && pp.stopSent,"pause_probe_keeps_original_completeness_gate")
    var lateClock=200.0
    let (tp,tlog)=try pausePilot()
    tp.nowOverride={lateClock};tp.stopAt=lateClock;tp.tick()
    lateClock+=2.01;tp.tick()
    try check(tlog.names==["pause","stop"] && tp.stopSent && tp.pauseStop.finalStopReason=="pause_ack_timeout","pause_ack_timeout_still_sends_final_stop")
    try tp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try check(tlog.names==["pause","stop"] && tp.pauseStop.lateAcks==1 && tp.pauseStop.duplicateAcks==0,"late_pause_ack_after_timeout_ignored")
    var ackClock=300.0
    let (ap,alog)=try pausePilot()
    ap.nowOverride={ackClock};ap.stopAt=ackClock;ap.tick()
    ackClock+=1.9
    try ap.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try check(ap.pauseStop.holding && ap.pauseStop.duplicateAcks==0,"late_but_in_time_pause_ack_accepted")
    ackClock+=0.29;ap.tick()
    try check(alog.names==["pause"] && !ap.stopSent,"late_ack_starts_its_own_window")
    ackClock+=0.02;ap.tick()
    try check(alog.names==["pause","stop"],"late_ack_window_elapsed_then_stop")
    let dupClock=400.0
    let (dp,dlog)=try pausePilot()
    dp.nowOverride={dupClock};dp.stopAt=dupClock;dp.tick()
    try dp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try dp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try check(dp.pauseStop.duplicateAcks==1 && dlog.names==["pause"] && !dp.stopSent && !dp.policy.stopObserved,"duplicate_pause_ack_counted_not_stop")
    let devClock=500.0
    let (sp,slog)=try pausePilot()
    sp.nowOverride={devClock};sp.stopAt=devClock;sp.tick()
    try sp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try sp.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try check(sp.policy.stopObserved && sp.pauseStop.outcome == .deviceStopped && !slog.names.contains("stop") && sp.policy.state == .verifying,"device_stop_during_pause_cancels_probe_without_second_stop")
    try sp.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try check(!slog.names.contains("stop") && sp.policy.state == .verifying,"duplicate_end_never_sends_extra_stop")
    let cancelClock=600.0
    let (cp,clog)=try pausePilot()
    cp.nowOverride={cancelClock};cp.stopAt=cancelClock;cp.tick()
    try cp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    cp.fail("user_cancelled")
    try check(cp.firstFailure=="user_cancelled" && cp.stopSent && clog.names==["pause","stop"] && cp.pauseStop.outcome == .finalStopSent && !cp.pauseStop.active,"cancel_during_pause_sends_bounded_final_stop")
    let failClock=700.0
    let (fp,flog)=try pausePilot()
    fp.commandSink={r in if requestName(r)=="pause" {throw ProbeError.invalid("fixture_pause_write_failed")};flog.names.append(requestName(r))}
    fp.nowOverride={failClock};fp.stopAt=failClock;fp.tick()
    try check(flog.names==["stop"] && fp.stopSent && fp.pauseStop.outcome == .pauseSendFailed,"pause_write_failure_falls_back_to_direct_stop")
    var dropClock=800.0
    let (xp,xlog)=try pausePilot()
    xp.nowOverride={dropClock};xp.stopAt=dropClock;xp.tick()
    try xp.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    xp.abandonPauseProbe("disconnected_device_state_unknown")
    try check(xp.pauseStop.outcome == .aborted && !xp.pauseStop.active && xlog.names==["pause"] && !xp.stopSent,"disconnect_aborts_probe_without_fake_stop")
    xp.tick()
    try check(xlog.names==["pause"],"aborted_probe_no_immediate_stop")
    // finish() sets finished before exiting; emulate that post-state, then prove a
    // late tick cannot invent a stop command for a session that is already gone.
    xp.finished=true;dropClock+=30;xp.tick()
    try check(xlog.names==["pause"],"finished_session_never_sends_late_stop")
    var vClock=1100.0
    let (vp,vlog)=try pausePilot()
    vp.nowOverride={vClock};vp.stopAt=vClock;vp.tick()
    vp.requestStop(forceDirect:true)
    try check(vp.stopSent && !vp.pauseStop.active && vlog.names==["pause","stop"],"direct_stop_during_waiting_ack_retires_probe")
    try vp.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try check(vp.policy.state == .verifying && vlog.names==["pause","stop","info"],"direct_stop_then_stop_ack_enters_verification")
    var busyBody=infoBody;busyBody[50]=1
    try vp.handle(Packet(status:1,type:1,id:1,payload:busyBody))
    vClock+=0.16
    let retryCount=vlog.names.count
    vp.tick()
    try check(vlog.names.count==retryCount+1 && vlog.names.last=="info","verify_retry_runs_after_probe_retirement")
    let wClock=1200.0
    let (wp2,wlog2)=try pausePilot()
    wp2.nowOverride={wClock};wp2.stopAt=wClock;wp2.tick()
    wp2.fail("late_packet_error")
    try check(wp2.stopSent && !wp2.pauseStop.active && wp2.pauseStop.outcome == .finalStopSent && wlog2.names==["pause","stop"],"fail_during_waiting_ack_retires_probe_and_stops")
    var eClock=1300.0
    let (ep,elog)=try pausePilot()
    ep.nowOverride={eClock};ep.stopAt=eClock;ep.tick()
    eClock+=2.0
    try ep.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))
    try check(ep.pauseStop.awaitingAck && ep.pauseStop.lateAcks==1 && !ep.stopSent,"ack_at_exact_timeout_rejected_as_late")
    ep.tick()
    try check(elog.names==["pause","stop"],"poll_at_exact_timeout_sends_stop")
    let (rp,rlog)=try pausePilot()
    var stuck=PauseStopSequencer();_ = stuck.begin(at:0);stuck.pauseWritten();_ = stuck.acknowledge(at:0.1,windowMs:300)
    rp.pauseStop=stuck;rp.stopSent=true
    rp.requestStop(forceDirect:true)
    try check(!rp.pauseStop.active && rlog.names.isEmpty,"stop_already_sent_retires_residual_probe_without_command")
    let offClock=900.0
    let offLog=CommandLog()
    let offPilot=Pilot(try PilotOptions(pauseBase))
    offPilot.commandSink={r in offLog.names.append(requestName(r))}
    offPilot.policy=try active();offPilot.phase="streaming";offPilot.headerSeen=true
    offPilot.nowOverride={offClock};offPilot.stopAt=offClock;offPilot.deadline=offClock+10;offPilot.hardDeadline=offClock+60
    offPilot.tick()
    try check(offLog.names==["stop"] && offPilot.stopSent && offPilot.pauseStop.phase == .idle,"default_stop_path_unchanged_no_pause")
    let strayPilot=Pilot(try PilotOptions(pauseBase));strayPilot.policy=try active();strayPilot.phase="streaming"
    try rejects("stray_pause_ack_rejected_without_probe"){try strayPilot.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))}
    let earlyAckPilot=Pilot(try PilotOptions(pauseBase+["--pause-before-stop-ms","200"]));earlyAckPilot.policy=try active();earlyAckPilot.phase="streaming"
    try rejects("pause_ack_before_any_pause_request_rejected"){try earlyAckPilot.handle(Packet(status:1,type:0x18,id:0x82,payload:[2]))}

    // ---- Bounded unknown-layout recovery in owned stop verification ----
    func verifyPilot(clock:@escaping()->Double)throws->(Pilot,CommandLog) {
        let log=CommandLog()
        let pilot=Pilot(try PilotOptions(["scan"]))
        pilot.nowOverride=clock
        pilot.commandSink={r in log.names.append(requestName(r))}
        var p=try active();try p.frame(seq:24,flags:0);try p.requestStop();try p.observeStop();try p.verifyRequested()
        pilot.policy=p;pilot.phase="verify"
        try pilot.stopVerification.begin(at:clock())
        pilot.deadline=clock()+5;pilot.hardDeadline=clock()+60
        return (pilot,log)
    }
    let shortInfo=[UInt8](repeating:0x5a,count:40)
    var unknownState=infoBody;unknownState[50]=2
    var otherState=infoBody;otherState[50]=3
    var wrongFirmware=[UInt8](repeating:0,count:56)
    wrongFirmware.replaceSubrange(3..<8,with:Array("04.99".utf8));wrongFirmware.replaceSubrange(33..<38,with:Array("1.2.2".utf8))
    wrongFirmware.replaceSubrange(51..<56,with:Array("03.06".utf8))
    let shortClock=1000.0
    let (shortPilot,shortLog)=try verifyPilot(clock:{shortClock})
    try shortPilot.consumeNotification(fixtureWire(1,1,shortInfo))
    try check(shortPilot.policy.state == .verifying && shortPilot.stopVerification.unknownLayoutObservations==1
              && shortPilot.stopInfoUnknownBytes==40 && shortPilot.stopInfoUnknownState==nil
              && abs((shortPilot.stopVerification.retryAt ?? 0)-1000.15)<1e-9,"stop_info_short_layout_unknown_retains_unknown_schedules_readonly")
    try check(shortLog.names.isEmpty && shortPilot.policy.state == .verifying,"stop_info_recovery_never_resends_stop")
    let codeClock=1100.0
    let (codePilot,_)=try verifyPilot(clock:{codeClock})
    try codePilot.consumeNotification(fixtureWire(1,1,unknownState))
    try check(codePilot.stopInfoUnknownState==2 && codePilot.policy.state == .verifying && !codePilot.policy.stopObserved == false,"stop_info_unknown_state_byte_not_interpreted_as_paused")
    try codePilot.consumeNotification(fixtureWire(1,1,otherState))
    try check(codePilot.stopInfoUnknownState==3 && codePilot.stopVerification.unknownLayoutObservations==1
              && codePilot.stopVerification.duplicateUnknownLayout==1,"stop_info_other_state_also_unknown_duplicate_counted")
    var boundClock=1200.0
    let (boundPilot,boundLog)=try verifyPilot(clock:{boundClock})
    let originalCutoff=boundPilot.stopVerification.deadline
    for _ in 0..<4 {
        try boundPilot.consumeNotification(fixtureWire(1,1,shortInfo))
        boundClock+=0.16
        boundPilot.tick()
    }
    try check(boundPilot.stopVerification.unknownLayoutObservations==4
              && boundLog.names.filter({$0=="info"}).count==4
              && boundPilot.stopVerification.deadline==originalCutoff,"stop_info_retries_bounded_without_deadline_renewal")
    try rejects("stop_info_permanently_bad_fails_at_attempt_bound"){try boundPilot.consumeNotification(fixtureWire(1,1,shortInfo))}
    try check(!boundLog.names.contains("stop") && boundPilot.policy.state == .verifying,"stop_info_bad_never_labels_idle_or_restops")
    var delayedClock=1300.0
    let (delayedPilot,_)=try verifyPilot(clock:{delayedClock})
    try delayedPilot.consumeNotification(fixtureWire(1,1,shortInfo))
    delayedClock=1300.0+1.99
    try delayedPilot.consumeNotification(fixtureWire(1,1,infoBody))
    try check(delayedPilot.policy.state == .ended && delayedPilot.idleVerifiedAt != nil
              && !delayedPilot.policy.protocolAudioComplete,"stop_info_delayed_idle_before_cutoff_keeps_completeness_gate")
    try delayedPilot.consumeNotification(fixtureWire(1,1,infoBody))
    try check(delayedPilot.policy.state == .ended && delayedPilot.stopVerification.unknownLayoutObservations==1,"stop_info_duplicate_idle_after_verification_ignored")
    var cutoffClock=1400.0
    let (cutoffPilot,cutoffLog)=try verifyPilot(clock:{cutoffClock})
    try cutoffPilot.consumeNotification(fixtureWire(1,1,shortInfo))
    cutoffClock=1400.0+2.0
    try rejects("stop_info_idle_at_exact_cutoff_rejected"){try cutoffPilot.consumeNotification(fixtureWire(1,1,infoBody))}
    cutoffClock=1400.0+2.01
    try rejects("stop_info_idle_after_cutoff_rejected"){try cutoffPilot.consumeNotification(fixtureWire(1,1,infoBody))}
    try check(cutoffPilot.policy.state == .verifying && !cutoffLog.names.contains("stop"),"stop_info_cutoff_no_idle_no_restop")
    let fwClock=1500.0
    let (fwPilot,_)=try verifyPilot(clock:{fwClock})
    try rejects("stop_info_verify_firmware_mismatch_still_fatal"){try fwPilot.consumeNotification(fixtureWire(1,1,wrongFirmware))}
    try check(fwPilot.stopVerification.unknownLayoutObservations==0,"stop_info_firmware_mismatch_not_recovered")
    let initialPilot=Pilot(try PilotOptions(["scan"]));initialPilot.phase="info";initialPilot.nowOverride={1600.0}
    try rejects("stop_info_initial_short_still_fatal"){try initialPilot.handle(Packet(status:1,type:1,id:1,payload:shortInfo))}
    try rejects("stop_info_prestart_firmware_mismatch_still_fatal"){try initialPilot.handle(Packet(status:1,type:1,id:1,payload:wrongFirmware))}
    let sumClock=1700.0
    let (sumPilot,sumLog)=try verifyPilot(clock:{sumClock})
    var corruptInfoWire=fixtureWire(1,1,shortInfo);corruptInfoWire[corruptInfoWire.count-1]^=1
    try rejects("stop_info_checksum_failure_not_recovered"){try sumPilot.consumeNotification(corruptInfoWire)}
    try check(sumPilot.stopVerification.unknownLayoutObservations==0 && !sumLog.names.contains("stop"),"stop_info_checksum_not_recovery")
    let infoCancelClock=1800.0
    let (cancelPilot,cancelLog)=try verifyPilot(clock:{infoCancelClock})
    try cancelPilot.consumeNotification(fixtureWire(1,1,shortInfo))
    cancelPilot.requestStop(forceDirect:true)
    try check(cancelPilot.stopVerification.unknownLayoutObservations==1 && cancelLog.names.isEmpty
              && cancelPilot.policy.state == .verifying,"stop_info_cancel_error_sends_no_extra_stop")
    let okClock=1900.0
    let (okPilot,_)=try verifyPilot(clock:{okClock})
    try okPilot.consumeNotification(fixtureWire(1,1,infoBody))
    try check(okPilot.policy.state == .ended && okPilot.stopVerification.unknownLayoutObservations==0
              && !okPilot.policy.protocolAudioComplete,"stop_info_default_success_path_unchanged")
    // One coalesced notification: layout-unknown 01/01 followed by the matching
    // 1A0A. The recovery must return (not throw), so dispatch continues and the
    // terminal is still delivered in the same notification.
    let coClock=1950.0
    let (coPilot,coLog)=try verifyPilot(clock:{coClock})
    let coalesced=fixtureWire(1,1,shortInfo)+fixtureWire(0x1a,0x0a,[0,0,0,0,0]+le32(123))
    try coPilot.consumeNotification(coalesced)
    try check(coPilot.stopVerification.unknownLayoutObservations==1
              && coPilot.policy.terminalMatched && coPilot.terminalAt != nil
              && coPilot.assembly.buffered==0 && !coLog.names.contains("stop"),
              "coalesced_unknown_info_then_matching_terminal_still_dispatched")
    // Post-idle replies are validated, not blanket-ignored: only firmware-valid,
    // recording=false duplicates may be ignored during the drain.
    let postClock=2050.0
    let (postPilot,_)=try verifyPilot(clock:{postClock})
    try postPilot.consumeNotification(fixtureWire(1,1,infoBody))
    try check(postPilot.policy.state == .ended,"post_idle_setup_ended")
    var postBusyBody=infoBody;postBusyBody[50]=1
    try rejects("post_idle_recording_true_fails_closed"){try postPilot.consumeNotification(fixtureWire(1,1,postBusyBody))}
    try rejects("post_idle_wrong_firmware_fails_closed"){try postPilot.consumeNotification(fixtureWire(1,1,wrongFirmware))}
    try rejects("post_idle_malformed_fails_closed"){try postPilot.consumeNotification(fixtureWire(1,1,shortInfo))}
    try postPilot.consumeNotification(fixtureWire(1,1,infoBody))
    try check(postPilot.policy.state == .ended,"post_idle_valid_duplicate_idle_ignored")
    // A requery that is sent but never answered must hit the original 2s deadline in
    // tick, not the generic 5s timeout.
    var noRespClock=2200.0
    let noRespLog=CommandLog()
    let noRespPilot=Pilot(try PilotOptions(["scan"]))
    noRespPilot.nowOverride={noRespClock}
    noRespPilot.commandSink={r in noRespLog.names.append(requestName(r))}
    var nrp=try active();try nrp.frame(seq:24,flags:0);try nrp.requestStop();try nrp.observeStop()
    noRespPilot.policy=nrp;noRespPilot.phase="stopping";noRespPilot.deadline=noRespClock+5;noRespPilot.hardDeadline=noRespClock+60
    var capturedFails:[String]=[]
    noRespPilot.failureCapture={capturedFails.append($0)}
    try noRespPilot.maybeVerify()
    try check(noRespPilot.stopVerification.awaitingReply && noRespLog.names==["info"],"no_response_requery_outstanding")
    noRespClock=2200.0+1.999
    noRespPilot.tick()
    try check(capturedFails.isEmpty && noRespLog.names==["info"],"no_response_before_cutoff_still_waits")
    noRespClock=2200.0+2.0
    noRespPilot.tick()
    try check(capturedFails==["device_stop_unconfirmed"] && noRespLog.names==["info"],"no_response_exact_cutoff_enforced_not_generic_timeout")
    var sv=StopIdleVerification();try sv.begin(at:0);let svCut=sv.deadline
    sv.markReplyExpected()
    try check(sv.awaitingReply,"stop_deadline_tracks_outstanding_query")
    var deadlineOK=true;do{try sv.checkDeadline(at:1.999)}catch{deadlineOK=false}
    try check(deadlineOK,"stop_deadline_before_cutoff_allowed")
    try rejects("stop_deadline_exact_cutoff_rejected"){try sv.checkDeadline(at:2.0)}
    try sv.unknownLayout(at:0.1)
    try check(sv.deadline==svCut && abs((sv.retryAt ?? 0)-0.25)<1e-9 && sv.unknownLayoutObservations==1,"stop_unknown_layout_pure_no_deadline_renewal")
    try sv.unknownLayout(at:0.2)
    try check(sv.duplicateUnknownLayout==1 && sv.unknownLayoutObservations==1,"stop_unknown_layout_pure_duplicate_not_rescheduled")
    _ = try sv.takeDue(at:0.25)
    try rejects("stop_unknown_layout_pure_after_cutoff_rejected"){try sv.unknownLayout(at:2.0)}

    // ---- Manual workbench lifecycle (same Pilot, no BLE/hardware) ----
    func workbenchPilot()throws->(Pilot,CommandLog) {
        let log=CommandLog()
        let p=Pilot(try PilotOptions(["workbench"]))
        p.commandSink={r in log.names.append(requestName(r))}
        p.selectedDevice=UUID();p.phase="scan";p.deadline=p.now+3600;p.hardDeadline=p.now+3600
        p.decoder=try LiveOpus()
        return (p,log)
    }
    let (wbConnect,wbConnectLog)=try workbenchPilot()
    wbConnect.phase="idleCheck"
    try wbConnect.consumeNotification(fixtureWire(1,1,infoBody))
    try check(wbConnect.phase=="idleReady" && wbConnectLog.names.isEmpty && !wbConnect.workbenchSessionActive,
              "workbench_connection_alone_never_starts_capture")
    wbConnect.startManualTest()
    try check(wbConnect.phase=="idleCheck" && wbConnectLog.names==["info"],"workbench_start_requires_explicit_recheck")
    try wbConnect.consumeNotification(fixtureWire(1,1,infoBody))
    try check(wbConnect.phase=="starting" && wbConnectLog.names==["info","start"] && wbConnect.policy.ownsStart,
              "workbench_explicit_start_after_idle_recheck")
    let (wbBusy,wbBusyLog)=try workbenchPilot()
    wbBusy.phase="idleReady";wbBusy.workbenchIdleVerified=true
    wbBusy.startManualTest()
    var busyInfo=infoBody;busyInfo[50]=1
    try wbBusy.consumeNotification(fixtureWire(1,1,busyInfo))
    try check(wbBusy.phase=="idleBusy" && !wbBusy.manualStartPending && wbBusyLog.names==["info"]
              && !wbBusy.policy.ownsStart,"workbench_device_busy_refused_without_retry")
    wbBusy.refreshIdleWorkbench()
    try wbBusy.consumeNotification(fixtureWire(1,1,infoBody))
    try check(wbBusy.phase=="idleReady" && wbBusyLog.names==["info","info"],"workbench_refresh_busy_to_idle")
    var wbClock=3000.0
    let (wbSession,wbSessionLog)=try workbenchPilot()
    wbSession.nowOverride={wbClock}
    wbSession.policy=try active();wbSession.phase="streaming";wbSession.headerSeen=true
    wbSession.fileCrypto=fixtureCrypto;wbSession.decoder=try LiveOpus();wbSession.firstAt=wbClock
    try wbSession.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(24,4)))
    try check(wbSession.policy.frames==1 && wbSession.policy.lastFlag,"workbench_owned_audio_accepted")
    wbSession.requestStop()
    try check(wbSessionLog.names==["stop"] && wbSession.stopSent,"workbench_stop_command_sent")
    try wbSession.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try check(wbSession.policy.state == .verifying && wbSessionLog.names==["stop","info"],"workbench_stop_enters_verify")
    try wbSession.handle(Packet(status:1,type:1,id:1,payload:infoBody))
    try check(wbSession.policy.state == .ended && wbSession.idleVerifiedAt != nil,"workbench_stop_idle_verified")
    wbClock+=1.01
    wbSession.tick()
    try check(!wbSession.finished && wbSession.phase=="idleReady" && wbSession.policy.file==nil
              && wbSession.workbenchNotice?.contains("完整性未通过")==true,"workbench_session_resets_and_keeps_connection")
    let wbAfterStopLog=wbSessionLog.names.count
    try wbSession.consumeNotification(fixtureWire(1,1,infoBody))
    try check(wbSession.phase=="idleReady" && wbSessionLog.names.count==wbAfterStopLog,"workbench_no_auto_capture_after_reset")
    wbSession.beginOwnedStart()
    try check(wbSession.phase=="starting" && wbSession.policy.ownsStart && wbSessionLog.names.last=="start",
              "workbench_repeated_session_can_start_again")
    let (wbStale,wbStaleLog)=try workbenchPilot()
    wbStale.phase="idleReady"
    try wbStale.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(24,0)))
    try wbStale.consumeNotification(fixtureWire(0x1a,0x0a,[0,0,0,0,0]+le32(123)))
    try wbStale.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try wbStale.handle(Packet(status:1,type:0x1a,id:6,payload:le32(555)))
    try check(wbStale.workbenchStaleAudio==1 && wbStale.policy.file==nil && wbStale.policy.frames==0
              && wbStale.policy.state == .checking && wbStaleLog.names.isEmpty,
              "workbench_stale_audio_terminal_control_and_external_start_ignored")
    let (wbRecord,wbRecordLog)=try workbenchPilot()
    wbRecord.policy=try active();wbRecord.phase="streaming";wbRecord.fileCrypto=fixtureCrypto;wbRecord.decoder=try LiveOpus()
    wbRecord.finish("disconnected_device_state_unknown",2)
    try check(!wbRecord.finished && wbRecord.phase=="disconnected"
              && wbRecord.workbenchError?.contains("可能仍在录音")==true && wbRecordLog.names.isEmpty,
              "workbench_disconnect_during_recording_reports_unknown_no_retry")
    let (wbStartQuit,_)=try workbenchPilot()
    var wbStarting=PilotPolicy();try wbStarting.start(firmwareOK:true,idle:true);wbStartQuit.policy=wbStarting;wbStartQuit.phase="starting"
    wbStartQuit.finish("hard_timeout_device_state_unknown",2)
    try check(wbStartQuit.phase=="unknown" && wbStartQuit.workbenchError?.contains("未确认")==true,
              "workbench_quit_during_starting_marks_unknown")
    let (wbUnconfirmed,wbUnconfirmedLog)=try workbenchPilot()
    wbUnconfirmed.policy=try active();wbUnconfirmed.phase="streaming"
    wbUnconfirmed.fileCrypto=fixtureCrypto;wbUnconfirmed.decoder=try LiveOpus()
    wbUnconfirmed.requestStop()
    wbUnconfirmed.finish("device_stop_unconfirmed",2)
    try check(wbUnconfirmed.phase=="unknown" && wbUnconfirmedLog.names==["stop"] && !wbUnconfirmed.finished,
              "workbench_stop_unconfirmed_stays_unknown_no_retry")
    let (wbStopping,wbStoppingLog)=try workbenchPilot()
    wbStopping.policy=try active();wbStopping.phase="streaming";wbStopping.fileCrypto=fixtureCrypto;wbStopping.decoder=try LiveOpus()
    wbStopping.requestStop();wbStopping.phase="stopping"
    wbStopping.finish("disconnected_device_state_unknown",2)
    try check(wbStopping.phase=="disconnected" && wbStoppingLog.names==["stop"],"workbench_disconnect_during_stopping_no_retry")

    // Starting without an owned file id: wait for the session, stop it, then disconnect.
    var sdClock=4000.0
    let (sd,sdLog)=try workbenchPilot()
    sd.nowOverride={sdClock}
    var sdPolicy=PilotPolicy();try sdPolicy.start(firmwareOK:true,idle:true);sd.policy=sdPolicy;sd.phase="starting";sd.deadline=sdClock+3
    var sdDisconnected=false
    sd.disconnectWorkbench{ _ in sdDisconnected=true }
    try check(sd.workbenchDisconnectPending && sd.awaitingOwnedStop && sd.phase=="awaiting_owned_stop"
              && sdLog.names.isEmpty && !sdDisconnected,"disconnect_during_start_awaits_owned_session")
    try sd.handle(Packet(status:1,type:0x18,id:0x82,payload:[1]))
    try sd.handle(Packet(status:1,type:0x1a,id:6,payload:le32(123)))
    try check(sd.stopSent && sdLog.names==["stop"] && !sdDisconnected,"owned_session_stopped_before_disconnect")
    try sd.handle(Packet(status:1,type:0x18,id:0x82,payload:[0]))
    try sd.handle(Packet(status:1,type:1,id:1,payload:infoBody))
    try check(sd.policy.state == .ended && !sdDisconnected,"verified_idle_before_disconnect")
    sdClock+=1.01;sd.tick()
    try check(sdDisconnected && sd.phase=="disconnected" && !sd.workbenchDisconnectPending,"disconnect_only_after_session_settles")
    let (rs,rsLog)=try workbenchPilot()
    rs.policy=try active();rs.phase="streaming"
    let rsGeneration=rs.workbenchGeneration
    rs.rescanWorkbench()
    try check(rs.workbenchGeneration==rsGeneration && rs.phase=="streaming" && rsLog.names.isEmpty
              && rs.workbenchNotice?.contains("不能重新扫描")==true,"rescan_rejected_while_session_active")
    let (gb,_)=try workbenchPilot()
    gb.phase="idleReady";gb.workbenchDisconnectPending=true;gb.workbenchGeneration=5
    gb.forceDisconnectIfPending(generation:4,reason:"stale_timer")
    try check(gb.workbenchDisconnectPending && gb.phase=="idleReady","delayed_disconnect_generation_bound")
    gb.forceDisconnectIfPending(generation:5,reason:"current")
    try check(!gb.workbenchDisconnectPending && gb.phase=="disconnected","current_generation_disconnect_applied")
    let (vi,viLog)=try workbenchPilot()
    vi.phase="idleReady";vi.workbenchIdleVerified=false
    let viStatusBefore=WorkbenchStatus.describe(pilot:vi,candidates:0)
    vi.startManualTest()
    try check(!viStatusBefore.canStart && viLog.names.isEmpty && vi.phase=="idleReady","unverified_idle_cannot_start")
    vi.workbenchIdleVerified=true
    let viStatusAfter=WorkbenchStatus.describe(pilot:vi,candidates:0)
    try check(viStatusAfter.canStart,"verified_idle_enables_start")
    vi.startManualTest()
    try check(viLog.names==["info"] && vi.phase=="idleCheck","verified_idle_start_rechecks")
    let (df,_)=try workbenchPilot()
    df.decoder=nil;df.decoderFactory={nil};df.phase="starting"
    df.finish("audio_preflight_failed",2)
    let dfStatus=WorkbenchStatus.describe(pilot:df,candidates:0)
    try check(df.phase=="error" && df.workbenchError?.contains("解码器")==true && !dfStatus.canStart,
              "decoder_failure_never_becomes_ready")
    let (ic,icLog)=try workbenchPilot()
    ic.phase="idleReady";ic.workbenchIdleVerified=true
    ic.startManualTest()
    var icDone=false
    ic.disconnectWorkbench{ _ in icDone=true }
    try check(icDone && ic.phase=="disconnected" && !ic.manualStartPending && icLog.names==["info"],
              "disconnect_during_idle_check_clears_pending_start")
    try ic.consumeNotification(fixtureWire(1,1,infoBody))
    try check(ic.policy.file==nil && !ic.policy.ownsStart && icLog.names==["info"],
              "late_idle_after_disconnect_never_owns_start")
    let uc2Clock=5000.0
    let (uc2,uc2Log)=try workbenchPilot()
    uc2.nowOverride={uc2Clock};uc2.policy=try active();uc2.phase="streaming"
    uc2.fileCrypto=fixtureCrypto;uc2.decoder=try LiveOpus();uc2.firstAt=uc2Clock
    uc2.requestStop()
    var uc2Done=false
    uc2.disconnectWorkbench{ _ in uc2Done=true }
    try check(uc2.workbenchDisconnectPending && !uc2Done,"disconnect_waits_for_stop_settlement")
    uc2.finish("device_stop_unconfirmed",2)
    try check(uc2Done && uc2.phase=="disconnected" && uc2.workbenchError?.contains("可能仍在录音")==true
              && uc2Log.names==["stop"],"stop_unknown_preserved_through_disconnect")
    let (fd,fdLog)=try workbenchPilot()
    fd.phase="idleReady";fd.workbenchIdleVerified=true
    var decoderCreations=0;fd.decoderFactory={decoderCreations+=1;return try? LiveOpus()}
    fd.beginOwnedStart()
    try check(decoderCreations==1 && fd.phase=="starting" && fdLog.names==["start"],"fresh_decoder_per_capture")
    let (fd2,fd2Log)=try workbenchPilot()
    fd2.phase="idleReady";fd2.workbenchIdleVerified=true;fd2.decoderFactory={nil}
    fd2.beginOwnedStart()
    try check(fd2.phase=="idleReady" && fd2Log.names.isEmpty && fd2.workbenchError?.contains("解码器")==true,
              "decoder_failure_blocks_capture_start")
    let (cf10,_)=try workbenchPilot()
    cf10.phase="services";cf10.finish("service_missing",2)
    try check(cf10.phase=="error" && !WorkbenchStatus.describe(pilot:cf10,candidates:0).canStart
              && cf10.workbenchError?.contains("不会进入可试音")==true,"connect_failure_never_idle_ready")
    let (pf,_)=try workbenchPilot()
    pf.phase="notify";pf.finish("notify_failed",2)
    try check(pf.phase=="error" && !WorkbenchStatus.describe(pilot:pf,candidates:0).canStart,"protocol_failure_never_idle_ready")
    // Refresh deadline/stale callbacks and bounded transient phases.
    var wbRfClock=6000.0
    let (wbRf,wbRfLog)=try workbenchPilot()
    wbRf.nowOverride={wbRfClock};wbRf.phase="idleBusy";wbRf.deadline=wbRfClock-1
    wbRf.refreshIdleWorkbench()
    try check(wbRf.phase=="idleCheck" && wbRf.deadline==wbRfClock+5,"refresh_resets_idle_check_deadline")
    wbRfClock+=5.0
    try wbRf.consumeNotification(fixtureWire(1,1,infoBody))
    try check(wbRf.phase=="idleTimeout" && !wbRf.policy.ownsStart && wbRfLog.names==["info"],
              "late_idle_after_refresh_deadline_rejected")
    let (wbIt,wbItLog)=try workbenchPilot()
    wbIt.phase="idleCheck";wbIt.deadline=wbIt.now-1
    var wbItFails:[String]=[];wbIt.failureCapture={wbItFails.append($0)}
    wbIt.tick()
    try check(wbIt.phase=="idleTimeout" && wbItFails.isEmpty && wbItLog.names.isEmpty,
              "idle_check_timeout_becomes_visible_stale_state")
    let wbTpClock=6100.0
    let (wbTp,_)=try workbenchPilot()
    wbTp.nowOverride={wbTpClock};wbTp.phase="services";wbTp.deadline=wbTpClock-1
    var wbTpFails:[String]=[];wbTp.failureCapture={wbTpFails.append($0)}
    wbTp.tick()
    try check(wbTpFails==["timeout_services"],"transient_connect_phase_timeout_bounded")
    let (wbPs,_)=try workbenchPilot()
    wbPs.phase="scan";wbPs.deadline=wbPs.now-1
    var wbPsFails:[String]=[];wbPs.failureCapture={wbPsFails.append($0)}
    wbPs.tick()
    try check(wbPsFails.isEmpty,"scan_stays_persistent")
    let (wbPi,_)=try workbenchPilot()
    wbPi.phase="idleReady";wbPi.deadline=wbPi.now-1
    var wbPiFails:[String]=[];wbPi.failureCapture={wbPiFails.append($0)}
    wbPi.tick()
    try check(wbPiFails.isEmpty,"verified_idle_stays_persistent")
    let (wbSt,_)=try workbenchPilot()
    var trialReset=SpeechTrial();_ = trialReset.decoded(sequence:24,at:1,streaming:true)
    wbSt.speechTrial=trialReset
    wbSt.phase="services";wbSt.finish("service_missing",2)
    try check(wbSt.speechTrial.readyAt==nil,"speech_trial_reset_between_captures")
    let (wbQ,_)=try workbenchPilot()
    wbQ.policy=try active();wbQ.phase="streaming";wbQ.fileCrypto=fixtureCrypto;wbQ.decoder=try LiveOpus();wbQ.firstAt=wbQ.now
    wbQ.requestStop()
    var wbQUnknown:Bool?=nil
    wbQ.shutdownWorkbench{ wbQUnknown=$0 }
    wbQ.finish("device_stop_unconfirmed",2)
    try check(wbQUnknown==true && wbQ.phase=="disconnected" && wbQ.workbenchError?.contains("可能仍在录音")==true,
              "quit_unknown_completion_requires_acknowledgement")
    let (wbQ2,_)=try workbenchPilot()
    wbQ2.phase="idleReady"
    var wbQ2Unknown:Bool?=nil
    wbQ2.disconnectWorkbench{ wbQ2Unknown=$0 }
    try check(wbQ2Unknown==false && wbQ2.phase=="disconnected","idle_disconnect_not_marked_unknown")
    // Root review: failed stop THEN quit must retain evidence after policy reset.
    let (rootUnknown,_) = try workbenchPilot()
    rootUnknown.policy=try active();rootUnknown.phase="streaming"
    rootUnknown.finish("device_stop_unconfirmed",2)
    try check(rootUnknown.workbenchStopUnknown,"root_unknown_latched_after_session_reset")
    var rootQuitUnknown:Bool?=nil
    rootUnknown.shutdownWorkbench{rootQuitUnknown=$0}
    try check(rootQuitUnknown==true && rootUnknown.workbenchStopUnknown,"root_later_quit_preserves_unknown")
    rootQuitUnknown=nil
    rootUnknown.shutdownWorkbench{rootQuitUnknown=$0}
    try check(rootQuitUnknown==true,"root_cancel_then_quit_still_warns")
    let (rootRefresh,rootRefreshLog)=try workbenchPilot()
    rootRefresh.phase="idleTimeout"
    try check(rootRefresh.workbenchCanRefresh,"root_timeout_refresh_available")
    rootRefresh.refreshIdleWorkbench()
    try check(rootRefresh.phase=="idleCheck" && rootRefreshLog.names==["info"],"root_timeout_refresh_dispatches")
    rootRefresh.workbenchStopUnknown=true
    try rootRefresh.consumeNotification(fixtureWire(1,1,infoBody))
    try check(!rootRefresh.workbenchStopUnknown && rootRefresh.phase=="idleReady","root_verified_idle_clears_unknown")
    let (rootGeneration,_) = try workbenchPilot()
    rootGeneration.phase="idleReady"
    let rootOldGeneration=rootGeneration.workbenchGeneration
    rootGeneration.disconnectWorkbench()
    rootGeneration.phase="idleReady";rootGeneration.workbenchDisconnectPending=true
    rootGeneration.forceDisconnectIfPending(generation:rootOldGeneration,reason:"old_disconnect")
    try check(rootGeneration.phase=="idleReady" && rootGeneration.workbenchDisconnectPending,"root_completed_disconnect_invalidates_old_timer")
    // System microphone experimental output (fake sink, no audio IO).
    let (spo,spoLog)=try workbenchPilot()
    spo.phase="idleReady";spo.workbenchIdleVerified=true
    spo.setWorkbenchOutputMode(.blackHole)
    spo.outputFactory={_ in throw ProbeError.invalid("fixture_output_missing")}
    spo.beginOwnedStart()
    try check(spo.phase=="idleReady" && spoLog.names.isEmpty && spo.audioOutput==nil
              && spo.workbenchError?.contains("预检失败")==true,"system_preflight_failure_never_starts_ble")
    let (sp2,sp2Log)=try workbenchPilot()
    sp2.phase="idleReady";sp2.workbenchIdleVerified=true;sp2.setWorkbenchOutputMode(.blackHole)
    var outputs:[FakeWorkbenchOutput]=[]
    sp2.outputFactory={_ in let f=FakeWorkbenchOutput();outputs.append(f);return f}
    sp2.beginOwnedStart()
    try check(outputs.count==1 && sp2Log.names==["start"] && sp2.audioOutput === outputs[0]
              && sp2.workbenchSessionLimitSeconds==nil && sp2.policy.maxFrames==nil,"system_preflight_before_start_and_no_duration_limit")
    sp2.finish("scan_finished",0)
    try check(outputs[0].closed==1 && sp2.audioOutput==nil,"failure_closes_output_immediately")
    sp2.phase="idleReady";sp2.workbenchIdleVerified=true
    sp2.beginOwnedStart()
    try check(outputs.count==2 && sp2.audioOutput === outputs[1],"fresh_output_per_capture")
    let (mm,mmLog)=try workbenchPilot()
    var meterOutputs=0;mm.outputFactory={_ in meterOutputs+=1;return FakeWorkbenchOutput()}
    mm.phase="idleReady";mm.workbenchIdleVerified=true
    mm.beginOwnedStart()
    try check(meterOutputs==0 && mm.audioOutput==nil && mmLog.names==["start"],"meter_mode_never_instantiates_output")
    let (pp2,_)=try workbenchPilot()
    pp2.policy=try active();pp2.phase="streaming";pp2.headerSeen=true;pp2.fileCrypto=fixtureCrypto
    pp2.decoder=try LiveOpus();pp2.firstAt=pp2.now
    let fakeOut=FakeWorkbenchOutput();pp2.audioOutput=fakeOut;pp2.workbenchOutputMode = .blackHole
    try pp2.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(24,4)))
    try check(fakeOut.pushes==1,"system_mode_pushes_current_pcm_only")
    fakeOut.pending=0;pp2.finish("disconnected_device_state_unknown",2)
    try check(fakeOut.closed==1 && pp2.audioOutput==nil,"disconnect_closes_output")
    let routeClock=7000.0
    let (rc,rcLog)=try workbenchPilot()
    rc.nowOverride={routeClock};rc.phase="starting";rc.deadline=routeClock+10
    rc.workbenchOutputMode = .blackHole;rc.audioOutput=FakeWorkbenchOutput()
    rc.workbenchSessionDefaultOutput=(defaultOutput() ?? 1) &+ 1
    var rcFails:[String]=[];rc.failureCapture={rcFails.append($0)}
    rc.tick()
    try check(rcFails.isEmpty && rcLog.names.isEmpty && rc.audioOutput != nil,"default_output_change_keeps_bound_system_sink")
    var bigPolicy=PilotPolicy(maxFrames:16500)
    try bigPolicy.start(firmwareOK:true,idle:true);try bigPolicy.acknowledgeStart();try bigPolicy.opened(123)
    for i in 0..<16000 {try bigPolicy.frame(seq:UInt32(i),flags:i==0 ? 2:0)}
    try check(bigPolicy.frames==16000,"system_session_longer_budget_allows_16k_frames")
    // A full day at 50 frames/sec crosses both old budgets and the 1h watchdog.
    var continuous=PilotPolicy(maxFrames:nil)
    try continuous.start(firmwareOK:true,idle:true);try continuous.acknowledgeStart();try continuous.opened(123)
    var dayTail=TailTelemetry(), dayTimings=RecentTimingSamples()
    for i in 0..<4_320_000 {
        try continuous.frame(seq:UInt32(i),flags:i==0 ? 2:0)
        dayTail.record(sequence:UInt32(i),flags:0,received:Double(i)*0.02,stop:nil,idle:nil,terminal:nil)
        dayTimings.append(Double(i)*0.02)
    }
    try check(continuous.frames==4_320_000 && continuous.state == .streaming,"continuous_day_exceeds_old_frame_caps")
    try check(dayTail.frames==4_320_000 && dayTail.invalid==0 && dayTail.recent.count==32,"continuous_day_tail_window_bounded")
    try check(dayTimings.total==4_320_000 && dayTimings.values.count==2048 && dayTimings.values.min()==Double(4_320_000-2048)*0.02,"continuous_day_recent_statistics_bounded")
    try rejects("continuous_duplicate_still_rejected"){try continuous.frame(seq:4_319_999,flags:0)}
    try rejects("continuous_gap_still_rejected"){try continuous.frame(seq:4_320_001,flags:0)}
    var wireEnd=PilotPolicy(maxFrames:nil)
    try wireEnd.start(firmwareOK:true,idle:true);try wireEnd.acknowledgeStart();try wireEnd.opened(123)
    try wireEnd.frame(seq:PilotPolicy.maxSequence,flags:0)
    try rejects("continuous_crypto_counter_overflow_rejected"){try wireEnd.frame(seq:PilotPolicy.maxSequence+1,flags:0)}
    var invalidTimings=RecentTimingSamples();invalidTimings.append(.nan);invalidTimings.append(-1)
    try check(invalidTimings.total==0 && invalidTimings.values.isEmpty,"bad_timing_not_retained")
    let (continuousWire,continuousWireLog)=try workbenchPilot()
    var continuousClock=1000.0
    continuousWire.nowOverride={continuousClock}
    continuousWire.policy=PilotPolicy(maxFrames:nil)
    try continuousWire.policy.start(firmwareOK:true,idle:true)
    try continuousWire.policy.acknowledgeStart();try continuousWire.policy.opened(123)
    continuousWire.workbenchOutputMode = .blackHole;continuousWire.workbenchSessionLimitSeconds=nil
    continuousWire.headerSeen=true;continuousWire.fileCrypto=fixtureCrypto;continuousWire.phase="streaming"
    let continuousOutput=FakeWorkbenchOutput();continuousWire.audioOutput=continuousOutput
    for i in 0..<17000 {
        continuousClock=1000+Double(i)*0.02
        try autoreleasepool {try continuousWire.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(UInt32(i),i==0 ? 2:0)))}
        continuousWire.tick()
    }
    try check(continuousWire.policy.frames==17000 && continuousOutput.pushes==17000 && continuousWire.stopAt==nil && !continuousWire.stopSent && continuousWireLog.names.isEmpty,
              "wire_continuous_crosses_300s_and_16500_frames")
    try check(continuousWire.tailTelemetry.frames==17000 && continuousWire.tailTelemetry.invalid==0 && continuousWire.outputPushTimes.total==17000 && continuousWire.outputPushTimes.values.count==2048,
              "wire_long_session_statistics_bounded_and_complete")
    continuousClock+=3.01;continuousWire.tick()
    try check(continuousWire.firstFailure=="timeout_recording" && continuousOutput.closed==1 && continuousWireLog.names==["stop"],
              "long_session_stall_still_closes_output_and_stops_once")
    continuousWire.requestStop()
    try check(continuousWireLog.names==["stop"],"long_session_duplicate_stop_not_sent")
    var smallCeiling=PilotPolicy()
    try smallCeiling.start(firmwareOK:true,idle:true);try smallCeiling.acknowledgeStart();try smallCeiling.opened(123)
    for i in 0..<1500 {try smallCeiling.frame(seq:UInt32(i),flags:i==0 ? 2:0)}
    try rejects("default_cli_frame_budget_unchanged"){try smallCeiling.frame(seq:1500,flags:0)}
    let (lockP,_)=try workbenchPilot()
    lockP.phase="idleCheck";lockP.setWorkbenchOutputMode(.blackHole)
    try check(lockP.workbenchOutputMode == .meterOnly,"mode_locked_during_idle_recheck")
    lockP.phase="recording";lockP.setWorkbenchOutputMode(.blackHole)
    try check(lockP.workbenchOutputMode == .meterOnly,"mode_locked_during_recording")
    // Real error paths, without the failureCapture shortcut.
    let (realFail,realFailLog)=try workbenchPilot()
    realFail.policy=try active();realFail.phase="recording"
    let doomed=FakeWorkbenchOutput();doomed.pending=7;realFail.audioOutput=doomed
    realFail.fail("fixture_output_fault")
    try check(doomed.closed==1 && realFail.audioOutput==nil && realFailLog.names==["stop"],"real_output_failure_closes_before_device_stop")
    try realFail.consumeNotification(fixtureWire(0x1a,8,try fixtureSlice(24,4)))
    try check(doomed.pushes==0 && realFail.postFailureAudioNotifications==1,"post_failure_audio_never_forwarded")
    let (routeFail,routeFailLog)=try workbenchPilot()
    routeFail.policy=try active();routeFail.phase="recording";routeFail.deadline=routeFail.now+10
    let deadRoute=FakeWorkbenchOutput();deadRoute.routeFails=true;routeFail.audioOutput=deadRoute
    routeFail.tick()
    try check(deadRoute.closed==1 && routeFail.audioOutput==nil && routeFailLog.names==["stop"],"bound_route_loss_checked_without_new_pcm")
    let (drain,_)=try workbenchPilot();var drainClock=8000.0
    drain.nowOverride={drainClock};drain.policy=try active()
    try drain.policy.frame(seq:0,flags:6);try drain.policy.observeStop();try drain.policy.terminal(123)
    try drain.policy.verifyRequested();try drain.policy.verifiedIdle(true)
    drain.phase="verify";drain.idleVerifiedAt=8000;drain.lastAudioAt=8000
    let draining=FakeWorkbenchOutput();draining.pending=1;drain.audioOutput=draining
    drainClock=8000.5;drain.tick()
    try check(draining.closed==0 && drain.audioOutput != nil,"normal_tail_waits_for_system_output_queue")
    draining.pending=0;drainClock=8000.6;drain.tick()
    try check(draining.closed==1 && drain.audioOutput==nil && drain.phase=="idleReady","normal_tail_finishes_after_queue_drained")
    let (cause,_)=try workbenchPilot()
    cause.policy=try active();cause.phase="recording";cause.audioOutput=FakeWorkbenchOutput()
    cause.workbenchOutputFrames=7;cause.workbenchOutputPeak=8
    cause.fail("audio_output_backlog")
    try cause.policy.observeStop();try cause.policy.verifyRequested();try cause.policy.verifiedIdle(true)
    cause.finish("tail_drain_timeout",2)
    try check(cause.workbenchError?.contains("audio_output_backlog")==true && cause.workbenchError?.contains("960毫秒")==true && cause.workbenchLastDiagnostic.contains("阶段：recording"),"first_error_survives_tail_timeout_and_policy_reset")
    try check(cause.workbenchLastDiagnostic.contains("送出7帧") && cause.workbenchLastDiagnostic.contains("最高队列8帧"),"failed_session_preserves_bounded_counters")
    let (onlyTail,_)=try workbenchPilot();onlyTail.policy=try active()
    try onlyTail.policy.observeStop();try onlyTail.policy.verifyRequested();try onlyTail.policy.verifiedIdle(true)
    onlyTail.finish("tail_drain_timeout",2)
    try check(onlyTail.workbenchError==nil && onlyTail.workbenchNotice?.contains("tail_drain_timeout")==true && !onlyTail.workbenchLastDiagnostic.contains("audio_output_backlog"),"tail_timeout_alone_does_not_invent_first_error")
    let (unknownCause,_)=try workbenchPilot();unknownCause.policy=try active();unknownCause.phase="recording"
    unknownCause.fail("audio_output_backlog")
    unknownCause.finish("stop_unconfirmed",2)
    try check(unknownCause.phase=="unknown" && unknownCause.workbenchError?.contains("audio_output_backlog")==true && unknownCause.workbenchError?.contains("未确认")==true,"unknown_stop_also_preserves_first_failure")
    unknownCause.forceDisconnectWorkbench()
    try check(unknownCause.workbenchError?.contains("audio_output_backlog")==true,"disconnect_keeps_prior_failure_evidence")
    let (lostCause,_)=try workbenchPilot();lostCause.policy=try active();lostCause.phase="recording"
    lostCause.fail("live_gap");lostCause.finish("disconnected",2)
    try check(lostCause.workbenchError?.contains("live_gap")==true && lostCause.phase=="disconnected","link_loss_keeps_original_error")
    // PCM queue tests exercise the actual storage used by the HAL callback.
    try rejects("pcm_capacity_zero"){_ = try PCMOutputQueue(capacityFrames:0)}
    try rejects("pcm_capacity_unbounded"){_ = try PCMOutputQueue(capacityFrames:49)}
    var pcmQueue=try PCMOutputQueue(capacityFrames:2)
    let firstPCM=(0..<960).map{Float($0)/2000}
    let secondPCM=(0..<960).map{-Float($0)/2000}
    try pcmQueue.enqueue(firstPCM);try pcmQueue.enqueue(secondPCM)
    try rejects("pcm_full_rejected_atomically"){try pcmQueue.enqueue(firstPCM)}
    try check(pcmQueue.acceptedSamples==1920 && pcmQueue.queued==1920,"overflow_does_not_mutate_audio")
    var stereo=[Float](repeating:99,count:2*1920)
    stereo.withUnsafeMutableBufferPointer{pcmQueue.renderStereo(into:$0.baseAddress!,frames:1024)}
    var firstRenderOK=true
    for i in 0..<960 {if stereo[i*2] != firstPCM[i] || stereo[i*2+1] != firstPCM[i] {firstRenderOK=false}}
    for i in 0..<64 {if stereo[(960+i)*2] != secondPCM[i] {firstRenderOK=false}}
    try check(firstRenderOK,"stereo_render_preserves_sequence_across_frames")
    try pcmQueue.enqueue(firstPCM)
    stereo.withUnsafeMutableBufferPointer{pcmQueue.renderStereo(into:$0.baseAddress!,frames:1856)}
    var wrappedOK=true
    for i in 0..<896 {if stereo[i*2] != secondPCM[i+64] {wrappedOK=false}}
    for i in 0..<960 {if stereo[(896+i)*2] != firstPCM[i] {wrappedOK=false}}
    try check(wrappedOK,"ring_wrap_partial_read_preserves_every_sample")
    try check(pcmQueue.queued==0 && pcmQueue.renderedSamples==2880,"sample_accounting_no_loss")
    try rejects("invalid_pcm_nan_rejected"){try pcmQueue.enqueue([Float](repeating:.nan,count:960))}
    try check(pcmQueue.acceptedSamples==2880,"invalid_pcm_no_mutation")
    try pcmQueue.enqueue(firstPCM);pcmQueue.clear()
    stereo.withUnsafeMutableBufferPointer{pcmQueue.renderStereo(into:$0.baseAddress!,frames:960)}
    try check(stereo.prefix(1920).allSatisfy{$0==0} && pcmQueue.queued==0,"cancel_clears_audio_no_old_session_playback")
    // Actual public BLE arrival offsets, audio content deliberately not included.
    let replayOffsetsUs:[Int]=[0,120164,120325,120396,121939,125626,125895,209946,240112,270391,270571,330004,360115,360238,360309,362150,390153,390270,390346,391942,420028,420149,450158,450271,450339,451997,454571,480060,480181,480252,481885,483917,484034,540395,540511,540586,598957,630250,630373,657855,660034,660126,661889,664017,664094,720252,720374,750218,930256,930395,960102,960228,960301,961963,964230,964354,990118,990237,990307,1019991,1110027,1110162,1140084,1140207,1200123,1200247,1200316,1202507,1204123,1230171,1230308,1259986,1319071,1350069,1350229,1350307,1352284,1352380,1353843,1380097,1380215,1380286,1381984,1385126,1650085,1650206,1680235,1680383,1680467,1710204,1710353,1710423,1712501,1713962,1714041,1739925,1857939,1890185,1890341,1890416,1892327,1892417,1893888,1920181,1920355,1920427,1922010,1923965,2039078,2070219,2070343,2070418,2072369,2072446,2073913,2100108,2100235,2100306,2101946,2104040,2340233,2340349,2340418,2341922,2369961,2429967,2430102,2459988,2490076,2490208,2490277,2491782,2550204,2610165,2610295,2640143,2640258,2640333,2700151,2729951,2730093,2757890,2759927,2820155,2820282,2820352,2822109,2823942,2824117,2850163,2850297,2851934,2852012,2880061,2880213,2909979,3000436,3000576,3000692,3060119,3060255,3060329,3061916,3090072,3090200,3120453,3120559,3120629,3329930,3360129,3360255,3360328,3364328,3364459,3390098,3390206,3420137,3420293,3420364,3422042,3540108,3540239,3540314,3541894,3570136,3570261,3571978,3572092,3600121,3600243,3629939,3630067,3750202,3750343,3750419,3751965,3809932,3840099,3840227,3840297,3841961,3843861,3843936,3870090,4050128,4050260,4050388,4052337,4052445,4053826,4110006,4140095,4140217,4140289,4142722,4142822,4260033,4260149,4260226,4262192,4263900,4263999,4290518,4290648,4290717,4320092,4320210,4350218,4440168,4470141,4470259,4470332,4472510,4472631,4474032,4500072,4500197,4529985,4530102,4559908,4769970,4770196,4800200,4800330,4800412,4802746,4802832,4830253,4830387,4860091,4890052,4890169,4980313,4980446,4980525,4982440,4982542,4983870,5010452,5010574,5010656,5040096,5040209,5070196,5159885,5190169,5190278,5190346,5192387,5192488,5193898,5220081,5220192,5280623,5280766,5280837,5459048,5459164,5460858,5462907,5463002,5489990,5490108,5520254,5520397,5520471,5523168,5523250,5670104,5670224,5670301,5672378,5672465,5673825,5700113,5700240,5700316,5702329,5702417,5703876,6000056,6000183,6029868,6029999,6060137,6060268,6090187,6090311,6090388,6092069,6094029,6120003]
    func simulateQueue(_ capacity:Int)throws->(accepted:Int,rendered:Int,peak:Int,failed:Bool) {
        var q=try PCMOutputQueue(capacityFrames:capacity);var consumedClock=0
        var scratch=[Float](repeating:0,count:2048)
        for us in replayOffsetsUs {
            let target=Int(Double(us)*0.048)
            var gap=target-consumedClock
            while gap>0 {let n=min(1024,gap);scratch.withUnsafeMutableBufferPointer{q.renderStereo(into:$0.baseAddress!,frames:n)};gap-=n}
            consumedClock=target
            do {try q.enqueue(firstPCM)}catch{return(q.acceptedSamples,q.renderedSamples,q.peakSamples,true)}
        }
        while q.queued>0 {let n=min(1024,q.queued);scratch.withUnsafeMutableBufferPointer{q.renderStereo(into:$0.baseAddress!,frames:n)}}
        return(q.acceptedSamples,q.renderedSamples,q.peakSamples,false)
    }
    let strictReplay=try simulateQueue(8),burstReplay=try simulateQueue(48)
    try check(strictReplay.failed,"real_ble_timing_reproduces_original_8_frame_failure")
    try check(!burstReplay.failed && burstReplay.accepted==312*960 && burstReplay.rendered==burstReplay.accepted,"same_ble_timing_all_samples_delivered_with_trial_capacity")
    try check(burstReplay.peak<=48*960 && burstReplay.peak>8*960,"real_timing_peak_recorded_not_hidden")
    event("self_tests_passed",["checks":count,"hardware_used":false,"audio_saved":false,"synthetic_wav_fixtures_only":true])
}
