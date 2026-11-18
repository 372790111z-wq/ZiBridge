import Foundation

// A cached peripheral is only a connection candidate, never recording authority.
// Return an index only for one exact user-selected UUID; never pick a neighbour.
func knownPeripheralIndex(selected: UUID?, retrieved: [UUID]) -> Int? {
    guard let selected else { return nil }
    let matches = retrieved.indices.filter { retrieved[$0] == selected }
    return matches.count == 1 ? matches[0] : nil
}

// Fixed-size, first-observation-only telemetry. It cannot grant session authority.
struct PreparationTiming {
    enum Stage: String, CaseIterable {
        case began, bluetoothReady, scanStarted, connectRequested, connected
        case servicesReady, characteristicsReady, notifyReady, initialIdle
        case keyRequested, keyReady, startRequested, startAck, newFile
        case streamRequested, headerReady, firstDecoded, readyPresented
    }
    private(set) var times: [Stage: Double] = [:]
    private(set) var invalidObservations = 0
    @discardableResult mutating func mark(_ stage: Stage, at time: Double) -> Bool {
        guard times[stage] == nil else { return false }
        guard time.isFinite, time >= 0, time >= (times.values.max() ?? 0) else {
            invalidObservations += 1; return false
        }
        times[stage] = time; return true
    }
    func elapsed(_ from: Stage, _ to: Stage) -> Double? {
        guard let a = times[from], let b = times[to], b >= a else { return nil }
        return b - a
    }
    var metrics: [String: Double] {
        let intervals: [(String, Stage, Stage)] = [
            ("tool_begin_to_first_pcm_s", .began, .firstDecoded),
            ("tool_begin_to_ready_presented_s", .began, .readyPresented),
            ("preflight_and_bluetooth_s", .began, .bluetoothReady),
            ("scan_to_connect_request_s", .scanStarted, .connectRequested),
            ("connect_s", .connectRequested, .connected),
            ("service_discovery_s", .connected, .servicesReady),
            ("characteristic_discovery_s", .servicesReady, .characteristicsReady),
            ("notification_enable_s", .characteristicsReady, .notifyReady),
            ("initial_info_s", .notifyReady, .initialIdle),
            ("key_exchange_s", .keyRequested, .keyReady),
            ("idle_recheck_to_start_s", .keyReady, .startRequested),
            ("start_to_ack_s", .startRequested, .startAck),
            ("ack_to_new_file_s", .startAck, .newFile),
            ("new_file_to_subscribe_s", .newFile, .streamRequested),
            ("subscribe_to_header_s", .streamRequested, .headerReady),
            ("header_to_first_pcm_s", .headerReady, .firstDecoded),
            ("start_to_first_pcm_s", .startRequested, .firstDecoded),
            ("first_pcm_to_ready_presented_s", .firstDecoded, .readyPresented)
        ]
        var result: [String: Double] = [:]
        for (name, from, to) in intervals { if let value = elapsed(from, to) { result[name] = value } }
        return result
    }
}
