import Foundation
import AppKit

// Manual workbench UI. It drives the SAME Pilot controller/protocol used by the CLI;
// there is no second BLE or packet implementation here. BLE is instantiated only
// when the user presses Scan. Connection alone never starts capture; every Start
// rechecks firmware+idle; the first valid current PCM is the only "Ready" signal.

struct WorkbenchStatus {
    static let retentionNotice = "设备可能保留本次录音并在重连飞书后同步；电脑不保存音频。"
    static let limitsText =
        "边界：仅内存试音，不保存、不回放、不读历史；设备可能保留并同步飞书。\n" +
        "“系统麦克风（BlackHole 2ch）”是手动实验：需在微信/ZiVoice 里手动选择 “BlackHole 2ch” 输入；不修改默认输入/输出/音量，不暂停音乐。\n" +
        "突发缓冲最多960毫秒，随到随播、不预填；低延迟尚未验收。\n" +
        "队列写入≠微信/ZiVoice 已收到；没有客户检测、自动启停或专用 “ZiVoice Bridge 麦克风” HAL 驱动（未实现）。\n" +
        "连接≠收音就绪；首尾/声学完整性未验收。停止须经设备确认空闲，未确认显示未知。"
    let title: String
    let detail: String
    let canStart: Bool
    let canStop: Bool
    let canScan: Bool
    let canConnect: Bool
    let canDisconnect: Bool
    let level: Double
    let mode: WorkbenchOutputMode
    let modeLocked: Bool
    let outputSummary: String
    let sessionLimitSeconds: Double?

    static func describe(pilot: Pilot?, candidates: Int) -> WorkbenchStatus {
        guard let p = pilot else {
            return WorkbenchStatus(title: "未扫描", detail: "点击“扫描”才会启用蓝牙；连接本身不会录音。",
                                   canStart: false, canStop: false, canScan: true, canConnect: false,
                                   canDisconnect: false, level: 0, mode: .meterOnly, modeLocked: true,
                                   outputSummary: "BlackHole 2ch：未检查 · 默认输出：未检查（不修改）",
                                   sessionLimitSeconds: 15)
        }
        let connected = p.workbenchLinkReady
        let recording = p.phase == "recording"
        let remaining = p.stopAt.map { max(0, $0 - p.now) }
        let remainText = remaining.map { String(format: "%.1f", $0) } ?? "-"
        let audio = p.workbenchAudioAvailability()
        let systemMode = p.workbenchOutputMode == .blackHole
        var title: String, detail = ""
        switch p.phase {
        case "scan":
            title = candidates == 0 ? "扫描中…" : "已发现 \(candidates) 台候选"
            detail = candidates == 0 ? "请让录音豆靠近并处于唤醒状态。" : "选择设备后点“连接”。"
        case "connecting": title = "连接中…"
        case "services", "characteristics", "notify": title = "建立连接…"
        case "info", "key": title = "正在握手并核对固件…"
        case "idleCheck": title = "正在核对设备空闲与固件…"
        case "idleReady":
            title = "已连接 · 未收音"
            detail = p.workbenchNotice ?? "设备空闲。点“开始试音”后才会请求收音。"
        case "idleBusy":
            title = "已连接 · 设备正在录音"
            detail = p.workbenchNotice ?? "本工具不会接管外部录音。请先在设备上停止。"
        case "starting": title = "已发送开始，等待设备确认…"
        case "head": title = "已开始；等待实时流头…"
        case "streaming": title = "等待有效当前声音…"
        case "recording":
            if systemMode {
                title = "可以说话 · 持续收音（点击结束停止）"
                detail = "需在微信/ZiVoice 手动选择 BlackHole 2ch；队列写入不等于客户已收到。"
            } else {
                title = "可以说话 · 仅电平 · 上限15秒（剩余 \(remainText)s）"
                detail = "已收到当前音频；本模式不向任何应用送声。"
            }
        case "pausing", "stopping", "verify": title = "正在停止并核验设备空闲…"
        case "idleTimeout": title = "设备状态检查超时"
        case "unknown": title = "设备停止状态未确认"
        case "disconnected": title = "已断开"
        case "error": title = "连接不可用"
        default: title = p.phase
        }
        if let e = p.workbenchError, !e.isEmpty { detail = e }
        let sessionActive = p.workbenchSessionActive
        let level = recording || p.phase == "streaming" ? min(1, p.lastRms * 8) : 0
        let canStart = connected && p.phase == "idleReady" && !sessionActive
            && p.workbenchIdleVerified && p.decoder != nil
            && (!systemMode || audio.blackHoleAvailable)
        return WorkbenchStatus(
            title: title, detail: detail,
            canStart: canStart,
            canStop: sessionActive && !p.stopSent,
            canScan: (p.phase == "disconnected" || p.phase == "error") && !sessionActive && !p.workbenchDisconnectPending,
            canConnect: p.phase == "scan" && !p.candidates.isEmpty,
            canDisconnect: (connected || sessionActive) && !p.workbenchDisconnectPending,
            level: level,
            mode: p.workbenchOutputMode,
            modeLocked: p.workbenchModeLocked,
            outputSummary: audio.summary,
            sessionLimitSeconds: systemMode ? nil : 15)
    }
}

final class WorkbenchController {
    private(set) var pilot: Pilot?
    var onChange: (() -> Void)?
    private var preferredMode: WorkbenchOutputMode = .blackHole
    var selectedMode: WorkbenchOutputMode { pilot?.workbenchOutputMode ?? preferredMode }
    var candidates: [(id: UUID, rssi: Int)] { pilot?.candidates ?? [] }
    var status: WorkbenchStatus { WorkbenchStatus.describe(pilot: pilot, candidates: candidates.count) }
    var needsShutdown: Bool {
        guard let p = pilot else { return false }
        return p.peripheral != nil || p.workbenchSessionActive || p.workbenchStopUnknown
    }
    func scan() {
        if let p = pilot {
            if p.phase == "disconnected" || p.phase == "error" { p.rescanWorkbench() }
            return
        }
        // BLE is created only here, on explicit user action.
        let p = Pilot(try! PilotOptions(["workbench"]))
        p.onUpdate = { [weak self] in self?.onChange?() }
        p.workbenchOutputMode = preferredMode
        pilot = p
        p.begin()
        onChange?()
    }
    func connect(_ id: UUID) { pilot?.selectDevice(id) }
    func start() { pilot?.startManualTest() }
    func stop() { pilot?.requestStop() }
    func refresh() { pilot?.refreshIdleWorkbench() }
    func disconnect() { pilot?.disconnectWorkbench() }
    func setMode(_ mode: WorkbenchOutputMode) {
        if let p = pilot { p.setWorkbenchOutputMode(mode) }
        else { preferredMode = mode; onChange?() }
    }
    func shutdown(_ completion: @escaping (Bool) -> Void) {
        guard let p = pilot else { completion(false); return }
        p.shutdownWorkbench(completion: completion)
    }
}

// One connection control, backed by the existing controller guards.
// No UI state can itself declare audio ready or confirm device stop.
enum WorkbenchConnectionAction: Equatable {
    case scan, connect, disconnect, wait
    static func resolve(_ status: WorkbenchStatus) -> WorkbenchConnectionAction {
        if status.canScan { return .scan }
        if status.canConnect { return .connect }
        if status.canDisconnect { return .disconnect }
        return .wait
    }
}

final class WorkbenchWindow: NSObject {
    let window: NSWindow
    let controller: WorkbenchController
    private let statusLabel = NSTextField(labelWithString: "未连接")
    private let detailLabel = NSTextField(wrappingLabelWithString: "点击连接，查找附近的录音豆。")
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)
    private let startButton = NSButton(title: "开始收音", target: nil, action: nil)
    private let stopButton = NSButton(title: "结束", target: nil, action: nil)
    private let refreshButton = NSButton(title: "重新检查", target: nil, action: nil)
    private let detailsButton = NSButton(title: "详情", target: nil, action: nil)
    private let helpButton = NSButton(title: "?", target: nil, action: nil)
    private let level = NSLevelIndicator(frame: .zero)
    private let clockLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "断开后，可回手机飞书连接。")
    private let limitsLabel = NSTextView()
    private let detailsScroll = NSScrollView()
    private let statusPanel = NSBox()
    private let separator = NSBox()
    private let modeLabel = NSTextField(labelWithString: "用途")
    private var detailsExpanded = false
    private var timer: Timer?
    private var lastCandidateKey = ""
    private var statusItem: NSStatusItem?
    private var connectionAction: WorkbenchConnectionAction = .wait
    private let accent = NSColor(calibratedRed: 0.33, green: 0.42, blue: 0.28, alpha: 1)

    init(controller: WorkbenchController, show: Bool = true) {
        self.controller = controller
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 334),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Bridge"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        clockLabel.textColor = .secondaryLabelColor
        clockLabel.alignment = .right
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        limitsLabel.font = .systemFont(ofSize: 11)
        limitsLabel.textColor = .secondaryLabelColor
        limitsLabel.isSelectable = true
        limitsLabel.isEditable = false
        limitsLabel.drawsBackground = false
        limitsLabel.isVerticallyResizable = true
        limitsLabel.isHorizontallyResizable = false
        limitsLabel.autoresizingMask = [.width]
        limitsLabel.textContainer?.widthTracksTextView = true
        detailsScroll.hasVerticalScroller = true
        detailsScroll.drawsBackground = false
        detailsScroll.documentView = limitsLabel
        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.textColor = .secondaryLabelColor
        modePopup.addItem(withTitle: "作为麦克风 · BlackHole 2ch")
        modePopup.addItem(withTitle: "仅测试收音 · 不送给应用")
        devicePopup.addItem(withTitle: "录音豆 · 未连接")
        devicePopup.setAccessibilityLabel("选择录音豆")
        modePopup.setAccessibilityLabel("收音用途")
        level.minValue = 0; level.maxValue = 1; level.doubleValue = 0
        level.levelIndicatorStyle = .continuousCapacity
        level.fillColor = accent
        level.setAccessibilityLabel("当前收音电平")
        statusPanel.boxType = .custom
        statusPanel.cornerRadius = 10
        statusPanel.borderColor = .separatorColor
        statusPanel.fillColor = NSColor.controlBackgroundColor
        statusPanel.contentViewMargins = .zero
        separator.boxType = .separator
        for button in [connectButton, startButton, stopButton, refreshButton, detailsButton, helpButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        startButton.bezelColor = accent
        helpButton.setAccessibilityLabel("使用说明")
        detailsButton.setAccessibilityIdentifier("bridge-details")
        connectButton.setAccessibilityIdentifier("bridge-device-connect")
        startButton.setAccessibilityIdentifier("bridge-live-audio-start")
        stopButton.setAccessibilityIdentifier("bridge-live-audio-stop")
        modePopup.setAccessibilityIdentifier("bridge-system-microphone")
        statusLabel.setAccessibilityIdentifier("bridge-session-state")
        for view in [statusPanel, devicePopup, connectButton, startButton, stopButton, statusLabel,
                     detailLabel, level, clockLabel, refreshButton, modeLabel, modePopup, hintLabel,
                     separator, footerLabel, detailsButton, helpButton, detailsScroll] {
            window.contentView?.addSubview(view)
        }
        modePopup.target = self; modePopup.action = #selector(modeTapped)
        connectButton.target = self; connectButton.action = #selector(connectionTapped)
        startButton.target = self; startButton.action = #selector(startTapped)
        stopButton.target = self; stopButton.action = #selector(stopTapped)
        refreshButton.target = self; refreshButton.action = #selector(refreshTapped)
        detailsButton.target = self; detailsButton.action = #selector(detailsTapped)
        helpButton.target = self; helpButton.action = #selector(helpTapped)
        controller.onChange = { [weak self] in self?.refreshUI() }
        layoutControls()
        refreshUI()
        if show {
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshUI() }
    }
    deinit { timer?.invalidate() }

    private func layoutControls() {
        let offset: CGFloat = detailsExpanded ? 226 : 0
        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x, y: y + offset, width: w, height: h)
        }
        place(devicePopup, 24, 276, 250, 32)
        place(connectButton, 282, 276, 90, 32)
        place(startButton, 392, 276, 130, 32)
        place(stopButton, 530, 276, 96, 32)
        place(statusPanel, 24, 126, 602, 132)
        place(statusLabel, 42, 222, 405, 23)
        place(clockLabel, 475, 224, 128, 18)
        place(detailLabel, 42, 166, 560, 48)
        place(level, 42, 143, 423, 11)
        place(refreshButton, 482, 133, 124, 28)
        place(modeLabel, 26, 91, 40, 20)
        place(modePopup, 72, 85, 390, 30)
        place(hintLabel, 26, 61, 598, 18)
        place(separator, 24, 47, 602, 1)
        place(footerLabel, 26, 18, 440, 18)
        place(detailsButton, 504, 10, 74, 30)
        place(helpButton, 588, 10, 38, 30)
        detailsScroll.frame = NSRect(x: 26, y: 16, width: 598, height: 210)
        limitsLabel.frame.size.width = detailsScroll.contentSize.width
        limitsLabel.minSize = NSSize(width: 0, height: 210)
        limitsLabel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailsScroll.isHidden = !detailsExpanded
    }

    private func refreshUI() {
        let s = controller.status
        let p = controller.pilot
        connectionAction = WorkbenchConnectionAction.resolve(s)
        switch connectionAction {
        case .scan: connectButton.title = "连接"
        case .connect: connectButton.title = "连接设备"
        case .disconnect: connectButton.title = "断开"
        case .wait: connectButton.title = p?.phase == "scan" ? "扫描中…" : "请稍候"
        }
        connectButton.isEnabled = connectionAction != .wait
        startButton.isEnabled = s.canStart
        stopButton.isEnabled = s.canStop
        refreshButton.isEnabled = p?.workbenchCanRefresh == true
        refreshButton.isHidden = !refreshButton.isEnabled
        level.doubleValue = s.level
        modePopup.isEnabled = p == nil || !s.modeLocked
        let system = controller.selectedMode == .blackHole
        modePopup.selectItem(at: system ? 0 : 1)
        hintLabel.stringValue = system ? "在 ZiVoice 或微信中选择 BlackHole 2ch 作为麦克风。" : "只查看收音电平，不向其他应用传送声音。"
        var title = s.title
        var detail = s.detail
        if p == nil { title = "未连接"; detail = "点击连接，查找附近的录音豆。" }
        if p?.phase == "recording" {
            title = system ? "正在收音 · 麦克风已启用" : "正在测试收音"
            detail = system ? "声音正在送往 BlackHole 2ch；请在目标应用确认收音。" : "仅显示当前声音，不保存或传送给应用。"
        }
        if p?.phase == "idleReady", p?.workbenchError == nil {
            title = "已连接 · 未收音"
            detail = p?.workbenchNotice ?? "点击“开始收音”，等待声音就绪后再说话。"
            if system, p?.workbenchAudioAvailability().blackHoleAvailable != true {
                detail = "BlackHole 2ch 不可用，请展开详情检查；也可选择仅测试收音。"
            }
        }
        // A technical failure remains visible; the details retain the exact evidence.
        if let error = p?.workbenchError, !error.isEmpty {
            detail = String(error.prefix(150))
        }
        statusLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.toolTip = s.detail
        if let stop = p?.stopAt, p?.workbenchSessionActive == true {
            let seconds = Int(ceil(max(0, stop - (p?.now ?? 0))))
            clockLabel.stringValue = String(format: "剩余 %d:%02d", seconds / 60, seconds % 60)
        } else if let first = p?.firstAt, p?.workbenchSessionActive == true {
            let elapsed = Int(max(0, (p?.now ?? first) - first))
            clockLabel.stringValue = String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
        } else { clockLabel.stringValue = "" }
        updateStatusItem(active: p?.workbenchSessionActive == true)
        let key = controller.candidates.map { "\($0.id.uuidString)/\($0.rssi)" }.joined(separator: ",")
        if key != lastCandidateKey {
            lastCandidateKey = key
            let selected = devicePopup.selectedItem?.representedObject as? String
            devicePopup.removeAllItems()
            for c in controller.candidates {
                devicePopup.addItem(withTitle: "录音豆 · \(c.id.uuidString.prefix(8))")
                devicePopup.lastItem?.representedObject = c.id.uuidString
            }
            if controller.candidates.isEmpty { devicePopup.addItem(withTitle: "录音豆 · 未连接") }
            if let selected, let idx = controller.candidates.firstIndex(where: { $0.id.uuidString == selected }) {
                devicePopup.selectItem(at: idx)
            }
        }
        devicePopup.isEnabled = s.canConnect
        if detailsExpanded {
            let metrics = p.map { "本次帧数 \($0.policy.frames) · RMS \(String(format: "%.4f", $0.lastRms))" } ?? "尚未开始收音"
            limitsLabel.string = WorkbenchStatus.retentionNotice + "\n" + s.outputSummary + "\n" + metrics + "\n" + WorkbenchStatus.limitsText + "\n" + (p?.workbenchError ?? p?.workbenchNotice ?? "")
        }
    }

    @objc private func connectionTapped() {
        // Re-evaluate at click time rather than trusting a 100ms-old visual state.
        switch WorkbenchConnectionAction.resolve(controller.status) {
        case .scan: controller.scan()
        case .connect:
            guard let raw = devicePopup.selectedItem?.representedObject as? String, let id = UUID(uuidString: raw) else { return }
            controller.connect(id)
        case .disconnect:
            let p = controller.pilot
            if p?.workbenchSessionActive == true || p?.workbenchStopUnknown == true || p?.phase == "idleBusy" {
                let alert = NSAlert()
                alert.messageText = "断开录音豆？"
                alert.informativeText = "本次收音会结束。若无法确认设备停止，录音豆可能仍在录音，需要你检查并按实体按钮结束。设备原有录音不会被本应用接管。"
                alert.addButton(withTitle: "断开")
                alert.addButton(withTitle: "返回")
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn, let self = self,
                          WorkbenchConnectionAction.resolve(self.controller.status) == .disconnect else { return }
                    self.controller.disconnect()
                }
            } else { controller.disconnect() }
        case .wait: break
        }
    }
    @objc private func startTapped() { controller.start() }
    @objc private func stopTapped() { controller.stop() }
    @objc private func refreshTapped() { controller.refresh() }
    @objc private func modeTapped() { controller.setMode(modePopup.indexOfSelectedItem == 0 ? .blackHole : .meterOnly) }
    @objc private func detailsTapped() {
        detailsExpanded.toggle()
        detailsButton.title = detailsExpanded ? "收起" : "详情"
        let old = window.frame
        window.setContentSize(NSSize(width: 650, height: detailsExpanded ? 560 : 334))
        var frame = window.frame; frame.origin.y = old.maxY - frame.height
        window.setFrame(frame, display: true)
        layoutControls(); refreshUI()
    }
    @objc private func helpTapped() {
        let alert = NSAlert()
        alert.messageText = "连接录音豆，开始收音"
        alert.informativeText = "1. 唤醒录音豆，暂时断开手机蓝牙连接，无需解绑。\n2. 点击连接，选择发现的设备后连接。\n3. 选好用途，点击开始收音，等待声音就绪。\n4. 结束收音后可保留连接；点断开后回手机飞书连接。\n\n首次连接需要蓝牙权限。本应用不采集 Mac 麦克风；ZiVoice／微信的麦克风权限由它们各自申请。\n\n" + WorkbenchStatus.retentionNotice + "\n系统模式持续收音，点击结束停止；仅测试收音仍限15秒。延迟和首尾完整性仍待验收。"
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: window)
    }
    @objc private func showFromStatus() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func stopFromStatus() { controller.stop() }
    private func updateStatusItem(active: Bool) {
        if active {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.title = "● Bridge 收音中"
                let menu = NSMenu()
                menu.addItem(withTitle: "显示 Bridge", action: #selector(showFromStatus), keyEquivalent: "").target = self
                menu.addItem(withTitle: "结束收音", action: #selector(stopFromStatus), keyEquivalent: "").target = self
                item.menu = menu; statusItem = item
            }
        } else if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
    }
}

final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    var workbench: WorkbenchWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示工作台", action: #selector(showWorkbench), keyEquivalent: "1").target = self
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(closeWorkbench), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Bridge 手动工作台", action: #selector(quitApp), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        let controller = WorkbenchController()
        let window = WorkbenchWindow(controller: controller)
        workbench = window
        window.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    // DBR-10: closing the window keeps the idle connection/app alive; reopen via Dock/menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkbench() }
        return true
    }
    @objc func showWorkbench() {
        workbench?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func closeWorkbench() { workbench?.window.close() }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = workbench?.controller, c.needsShutdown else { return .terminateNow }
        c.shutdown { unknown in
            // reply only after applicationShouldTerminate has returned terminateLater.
            DispatchQueue.main.async {
            if unknown {
                // Never silently discard an unconfirmed stop: explicit user acknowledgement.
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "设备停止状态未确认"
                alert.informativeText = "设备可能仍在录音；直接退出不会让它停止。请先检查指示灯。仍要退出吗？"
                alert.addButton(withTitle: "仍然退出")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    sender.reply(toApplicationShouldTerminate: true)
                } else {
                    sender.reply(toApplicationShouldTerminate: false)
                    self.showWorkbench()
                }
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
            }
        }
        return .terminateLater
    }
}

var retainedWorkbenchDelegate: WorkbenchAppDelegate?

func runWorkbenchApp() {
    let app = NSApplication.shared
    let delegate = WorkbenchAppDelegate()
    retainedWorkbenchDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

// No-hardware UI smoke: no BLE object is created (Scan is never pressed).
func runUISmoke() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var checks = 0
    func check(_ condition: Bool, _ name: String) {
        if !condition { print("{\"event\":\"ui_smoke_failed\",\"reason\":\"\(name)\"}"); exit(2) }
        checks += 1
    }
    let idle = WorkbenchStatus.describe(pilot: nil, candidates: 0)
    check(idle.title == "未扫描" && idle.canScan && !idle.canStart, "initial_idle_no_ble")
    let pilot = Pilot(try! PilotOptions(["workbench"]))
    pilot.phase = "scan"; pilot.candidates = [(UUID(), -40)]
    let scanned = WorkbenchStatus.describe(pilot: pilot, candidates: 1)
    check(scanned.canConnect && scanned.title.contains("1"), "scan_list_allows_connect")
    let meterStatus = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(meterStatus.mode == .meterOnly && meterStatus.sessionLimitSeconds == 15,
          "meter_mode_default_and_15s_limit")
    pilot.workbenchOutputMode = .blackHole
    pilot.phase = "recording"; pilot.stopAt = nil; pilot.workbenchSessionLimitSeconds = nil
    let systemStatus = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(systemStatus.mode == .blackHole && systemStatus.sessionLimitSeconds == nil
          && systemStatus.detail.contains("BlackHole 2ch"), "system_mode_continuous_and_target_text")
    check(systemStatus.outputSummary.contains("BlackHole 2ch"), "output_availability_shown")
    pilot.phase = "idleCheck"
    pilot.setWorkbenchOutputMode(.meterOnly)
    check(pilot.workbenchOutputMode == .blackHole && pilot.workbenchModeLocked, "mode_locked_during_idle_check")
    pilot.phase = "idleReady"
    let ready = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(ready.title.contains("未收音") && !ready.canStart, "connected_without_peripheral_never_ready")
    pilot.workbenchOutputMode = .meterOnly
    pilot.phase = "recording"; pilot.lastRms = 0.05; pilot.stopAt = pilot.now + 15
    let recording = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(recording.canStop && recording.title.contains("15") && recording.level > 0, "recording_meter_and_limit")
    pilot.phase = "unknown"; pilot.workbenchError = "停止状态未确认"
    let unknown = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(!unknown.canStart && unknown.detail.contains("未确认"), "unknown_blocks_start")
    pilot.phase = "disconnected"
    let disconnected = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(disconnected.canScan && !disconnected.canDisconnect, "disconnected_allows_rescan")
    let controller = WorkbenchController()
    let window = WorkbenchWindow(controller: controller, show: false)
    check(window.window.contentView != nil, "window_constructed_without_ble")
    let menuDelegate = WorkbenchAppDelegate()
    check(menuDelegate.applicationShouldTerminateAfterLastWindowClosed(app) == false,
          "window_close_keeps_app_alive")
    check(menuDelegate.applicationShouldHandleReopen(app, hasVisibleWindows: true) == true,
          "dock_reopen_supported")
    check(controller.pilot == nil, "no_pilot_until_user_scan")
    check(controller.selectedMode == .blackHole, "ui_system_default_without_capture")
    controller.setMode(.meterOnly)
    check(controller.selectedMode == .meterOnly && controller.pilot == nil, "mode_selection_before_connection_no_ble")
    check(WorkbenchConnectionAction.resolve(idle) == .scan, "toolbar_initial_scan")
    check(WorkbenchConnectionAction.resolve(scanned) == .connect, "toolbar_explicit_device_confirmation")
    check(WorkbenchConnectionAction.resolve(disconnected) == .scan, "toolbar_disconnect_reconnect_no_autostart")
    pilot.commandSink = { _ in }
    pilot.phase = "unknown"
    let ownedUnknown = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(WorkbenchConnectionAction.resolve(ownedUnknown) == .disconnect && !ownedUnknown.canStart,
          "unknown_keeps_disconnect_and_blocks_start")
    pilot.workbenchDisconnectPending = true
    let pending = WorkbenchStatus.describe(pilot: pilot, candidates: 0)
    check(WorkbenchConnectionAction.resolve(pending) == .wait, "pending_release_blocks_duplicate_action")
    let views = window.window.contentView!.subviews
    let details = views.compactMap { $0 as? NSButton }.first { $0.title == "详情" }!
    let initialHeight = window.window.contentView!.bounds.height
    check(initialHeight == 334, "compact_window_height")
    details.performClick(nil)
    check(window.window.contentView!.bounds.height == 560 && details.title == "收起", "details_expand_real_native_view")
    details.performClick(nil)
    check(window.window.contentView!.bounds.height == initialHeight && controller.pilot == nil,
          "details_collapse_preserves_idle_no_ble")
    let primary = views.compactMap { $0 as? NSButton }.filter { ["连接","开始收音","结束"].contains($0.title) }
    check(primary.count == 3 && Set(primary.map { $0.frame.minY }).count == 1, "one_row_actions")
    check(primary.first { $0.title == "开始收音" }?.isEnabled == false && primary.first { $0.title == "结束" }?.isEnabled == false,
          "disconnected_capture_buttons_disabled")
    check(WorkbenchStatus.retentionNotice.contains("飞书") && WorkbenchStatus.retentionNotice.contains("电脑不保存"), "retention_notice_prominent")
    check(WorkbenchStatus.limitsText.contains("仅内存试音") && !WorkbenchStatus.limitsText.contains("不说"), "user_facing_limits_wording")
    window.window.orderOut(nil)
    print("{\"event\":\"ui_smoke_passed\",\"checks\":\(checks),\"ble_instantiated\":false}")
    return 0
}
