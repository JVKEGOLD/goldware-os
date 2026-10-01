import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let whisper = WhisperEngine()
    private let cleanup = CleanupEngine()
    private let assistant = Assistant()
    private let store = Store()
    private let hud = HUD()
    private let library = Library()
    private lazy var taskBoard = TaskBoard(url: assistant.commandCenter)
    private let commandCenter = CommandCenter()
    private lazy var dashboard: DashboardWindow = {
        let d = DashboardWindow(home: commandCenter.baseURL)
        d.onRetry = { [weak self] in self?.startCommandCenter() }
        d.onShortcut = { [weak self] route in self?.run(route) }
        d.onState = { [weak self] state in self?.dashboardState = state; self?.writeStatus() }
        return d
    }()
    private lazy var historyWindow = HistoryWindow()
    private var launchedAtLogin = false
    private var dashboardState = "not opened"
    private let learner = Learner()
    private let vision = VisionController()
    private let controlCenter = ControlCenter()
    private var classicMenu: NSMenu!

    /// The last thing that can be taken back, for "GoldWare, undo" and the Undo chip.
    private enum UndoAction {
        case capture(requestID: String, title: String)
        case draft(path: URL, title: String)
        case paste(pid: pid_t, title: String)
    }
    private var lastUndo: (action: UndoAction, at: Date)?
    private var previewTimer: Timer?
    private var previewInFlight = false
    private var previewGeneration = 0

    private var recordingURL: URL?
    private var recordingMode: TalkMode = .dictate
    private var targetApp: NSRunningApplication?
    private var meterTimer: Timer?
    private var isRecording = false
    private var isBusy = false { didSet { syncWake() } }
    private let wake = WakeWord()
    private var handsFree = false
    private var lastTap: (mode: TalkMode, at: Date)?
    private var handsFreeLimit: DispatchWorkItem?
    private var statusLine = "Starting…"
    private var models: [String] = []
    private var termSource: DispatchSourceSignal?
    private var permissionTimer: Timer?
    private var outboxTimer: Timer?
    private var wasTrusted = false
    private var lastEvent = "launched"
    private var vaultLoadedAt = Date.distantPast

    private var cleanupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEnabled") }
    }
    private var cleanupModel: String {
        get { UserDefaults.standard.string(forKey: "cleanupModel") ?? GWConfig.current.localModel }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupModel") }
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened by macOS at login: start quietly in the menu bar and Dock, no window.
        if let e = NSAppleEventManager.shared().currentAppleEvent {
            launchedAtLogin = e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        }
    }

    /// goldwareos:// links from the dashboard open in the browser or other apps. Only the three
    /// whitelisted routes do anything.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { if let route = ShortcutRoute(url: url) { run(route) } }
    }

    /// Runs a dashboard shortcut: the same handler the voice phrase and the gesture call.
    func run(_ route: ShortcutRoute) {
        switch route {
        case .letsWork: Task { await openLetsWork() }
        case .lockUp: Task { await lockUp() }
        case .clearOut: Task { await clearOut() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        startCommandCenter()
        if !launchedAtLogin { dashboard.show() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)
        // Left click: GoldWare's control center. Right click (or Control-click): the classic menu.
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        classicMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        controlCenter.actions = .init(
            openDashboard: { [weak self] in self?.dashboard.show() },
            openTasks: { [weak self] in self?.openTasks() },
            openHistory: { [weak self] in self?.openHistory() },
            openVisionGuide: { [weak self] in self?.dashboard.show(tab: "vision") },
            undo: { [weak self] in self?.performUndo() },
            undoTitle: { [weak self] in self?.undoTitle },
            visionMode: { [weak self] in self?.vision.modeOn ?? false },
            setVisionMode: { [weak self] on in self?.vision.setMode(on) },
            quadrants: { HandControl.style == .quadrants },
            setQuadrants: { [weak self] on in self?.vision.setMode(true, style: on ? .quadrants : .pointer) },
            mirror: { VisionController.mirrorEnabled },
            setMirror: { VisionController.mirrorEnabled = $0 },
            wakeWord: { WakeWord.enabled },
            setWakeWord: { [weak self] on in self?.setWakeWord(on) },
            status: { [weak self] in self?.statusLine ?? "" },
            quit: { NSApp.terminate(nil) },
            agenda: { [weak self] in await self?.taskBoard.agenda() ?? Agenda() },
            restartWhisper: { [weak self] in self?.whisper.stop(); self?.whisper.start() })

        refreshVault()
        whisper.start()
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Recorder.requestPermission { granted in
            if !granted { self.statusLine = "Microphone access denied" }
        }

        hud.historyProvider = { [weak self] in self?.store.recent(limit: HistoryView.limit) ?? [] }
        hud.onCopy = { [weak self] d in
            Paster.copy(d.finalText)
            self?.hud.show("Copied. Paste with ⌘V.", orb: .breathing, autoHide: 1.4)
        }
        hud.onOpenHistory = { [weak self] in self?.openHistory() }
        assistant.library = library
        learner.onLearned = { [weak self] terms in
            self?.hud.show("Learned “\(terms.joined(separator: "”, “"))” from your edit", orb: .breathing, tint: .assistant, autoHide: 2.5)
        }
        hud.showIdle()
        vision.configure(agent: assistant, store: store)
        vision.onNotice = { [weak self] text in self?.hud.show(text, orb: .breathing, tint: .assistant, autoHide: 3) }
        vision.onDictate = { [weak self] start in self?.visionDictate(start) }
        vision.onSend = { [weak self] in self?.visionSend() }
        vision.onClear = { [weak self] in self?.visionClear() }
        vision.onLockUp = { [weak self] in Task { await self?.lockUp() } }
        vision.onLetsWork = { [weak self] in Task { await self?.openLetsWork() } }
        vision.onClearOut = { [weak self] in Task { await self?.clearOut() } }
        vision.start()
        configureWake()

        hotkey.onPress = { [weak self] mode in self?.keyPressed(mode) }
        hotkey.onRelease = { [weak self] mode, held in self?.keyReleased(mode, held: held) }
        hotkey.onOtherKey = { [weak self] code, held in self?.otherKey(code, whileHeld: held) }
        hotkey.onChord = { [weak self] in self?.toggleVisionMode() }
        hotkey.onUserInput = { [weak self] in self?.typedSince = true }
        hotkey.start()
        wasTrusted = AXIsProcessTrusted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermissions() }
        outboxTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.flushOutbox(quiet: true) }
        writeStatus()
        store.writeStats()

        Task { await self.bootEngines() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisper.stop()
        commandCenter.stopIfStartedHere()
    }

    // MARK: The GoldWare app: dashboard window, Dock, and menus

    private func startCommandCenter() {
        let root = VaultContext.resolveRoot()
        Task {
            let problem = await commandCenter.ensureRunning(root: root, log: Paths.dataDir.appendingPathComponent("server.log"))
            await MainActor.run {
                self.dashboard.serverReady(problem)
                if problem == nil { self.flushOutbox(quiet: true) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dashboard.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, tab) in [("Dashboard", "dashboard"), ("Voice", "voice"), ("Vision", "vision"), ("Office", "office")] {
            let mi = item(title, #selector(openTab(_:)))
            mi.representedObject = tab
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(item("What's on My Plate", #selector(showToday)))
        menu.addItem(item("Voice History", #selector(openHistory)))
        return menu
    }

    @objc private func openDashboard() { dashboard.show() }

    @objc private func openTab(_ sender: NSMenuItem) {
        dashboard.show(tab: sender.representedObject as? String)
    }

    @objc private func showToday() {
        Task { @MainActor in
            let agenda = await taskBoard.agenda()
            hud.show(agenda.summary, orb: .breathing, tint: .assistant, autoHide: 4)
        }
    }

    @objc private func reloadDashboard() { dashboard.reload() }
    @objc private func dashboardBack() { dashboard.goBack() }
    @objc private func dashboardForward() { dashboard.goForward() }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            top.submenu = sub
            main.addItem(top)
        }
        func sys(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            return mi
        }
        add(GWConfig.name, [
            sys("About \(GWConfig.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            sys("Hide \(GWConfig.name)", #selector(NSApplication.hide(_:)), "h"),
            sys("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            sys("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            sys("Quit \(GWConfig.name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        // Edit is what makes Cmd+C, Cmd+V, and Cmd+A work inside the dashboard.
        add("Edit", [
            sys("Undo", Selector(("undo:")), "z"),
            sys("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            sys("Cut", #selector(NSText.cut(_:)), "x"),
            sys("Copy", #selector(NSText.copy(_:)), "c"),
            sys("Paste", #selector(NSText.paste(_:)), "v"),
            sys("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let reload = item("Reload", #selector(reloadDashboard), key: "r")
        let back = item("Back", #selector(dashboardBack), key: "[")
        let forward = item("Forward", #selector(dashboardForward), key: "]")
        var tabs: [NSMenuItem] = []
        for (i, (title, tab)) in [("Dashboard", "dashboard"), ("Voice", "voice"), ("Vision", "vision"), ("Office", "office")].enumerated() {
            let mi = item(title, #selector(openTab(_:)), key: "\(i + 1)")   // Cmd+1 to 4
            mi.representedObject = tab
            tabs.append(mi)
        }
        add("View", [reload, back, forward, .separator()] + tabs + [.separator(),
            sys("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        add("Window", [
            sys("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            sys("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("\(GWConfig.name) Dashboard", #selector(openDashboard), key: "0"),
            item("What's on My Plate", #selector(showToday), key: "t"),
            item("Voice History", #selector(openHistory), key: "y"),
        ])
        return main
    }

    /// Finds the repo root and refreshes the saved prompts and snippets. Cheap, so it runs every few minutes.
    private func refreshVault(force: Bool = false) {
        guard force || Date().timeIntervalSince(vaultLoadedAt) > 300 else { return }
        vaultLoadedAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let context = VaultContext.load()
            DispatchQueue.main.async {
                self.assistant.context = context
                if !context.root.isEmpty { self.library.root = URL(fileURLWithPath: context.root) }
                self.library.refresh()
            }
        }
    }

    private func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted && !wasTrusted {
            hotkey.restart()
            lastEvent = "accessibility granted, hotkey reinstalled"
            hud.show("Accessibility on. Hold Right Option to talk.", orb: .breathing, autoHide: 2.5)
        }
        let changed = trusted != wasTrusted
        wasTrusted = trusted
        // status.json is for debugging: refresh it every 30 s instead of every tick, so idle stays idle.
        statusTicks += 1
        if changed || statusTicks % 15 == 0 { writeStatus() }
    }
    private var statusTicks = 0

    /// Diagnostics for whoever is helping debug: status.json in the data folder.
    private func writeStatus() {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "granted"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        default: mic = "not asked yet"
        }
        let status: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "accessibility": AXIsProcessTrusted() ? "granted" : "not granted",
            "microphone": mic,
            "status": statusLine,
            "last_event": lastEvent,
            "root": assistant.context.root,
            "pending_captures": store.pendingOutbox().count,
            "dashboard": dashboardState,
            "server": commandCenter.startedHere ? "started by the app" : "already running",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.dataDir.appendingPathComponent("status.json"))
        }
    }

    private func bootEngines() async {
        await MainActor.run { statusLine = "Loading speech model…" }
        for _ in 0..<60 {
            if whisper.problem != nil { break }   // missing binary or model: waiting will not help
            if whisper.problem != nil { break }   // missing binary or model: waiting will not help
            if await whisper.isReady() { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        models = await cleanup.availableModels()
        // The language model loads on first use (keep_alive is short), not at launch: it pins ~5 GB on a 16 GB Mac.
        let ready = await whisper.isReady()
        await MainActor.run {
            statusLine = ready ? "Ready" : (whisper.problem ?? "Speech engine failed to start (see whisper-server.log)")
            if ready, let bad = GWConfig.error { statusLine = bad; hud.show(bad, orb: .shaping, autoHide: 6) }
            if ready { hud.show("\(GWConfig.name) is here. Hold ⌥ to dictate, ⌘ to talk to me.", orb: .breathing, tint: .assistant, autoHide: 3) }
        }
        await MainActor.run { flushOutbox(quiet: true) }
    }

    // MARK: Talk keys
    //
    // Hold a key to talk and release to finish. Double-tap it to go hands-free, then
    // tap it again to finish. Escape cancels. A single short tap does nothing.

    private static let tapMax: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.5
    private static let handsFreeMax: TimeInterval = 600

    private func keyPressed(_ mode: TalkMode) {
        if wake.state == .capturing {
            if mode == .assistant { wake.finishCapture() }   // tap Right Command to send now
            return
        }
        if handsFree {
            if mode == recordingMode { endHandsFree(); finishRecording() }
            return
        }
        startRecording(mode)
    }

    private func keyReleased(_ mode: TalkMode, held: TimeInterval) {
        guard isRecording, !handsFree, mode == recordingMode else { return }
        if held >= Self.tapMax {
            finishRecording()
            return
        }
        if let tap = lastTap, tap.mode == mode, Date().timeIntervalSince(tap.at) < Self.doubleTapWindow + Self.tapMax {
            // Second tap: keep this recording running without the key held.
            lastTap = nil
            handsFree = true
            let key = mode == .assistant ? "Right Command" : "Right Option"
            hud.show("\(mode == .assistant ? "\(GWConfig.name) is listening" : "Listening"), hands-free. Tap \(key) to finish, Esc to cancel.",
                     orb: .listening, tint: mode == .assistant ? .assistant : .plain)
            let limit = DispatchWorkItem { [weak self] in
                guard let self, self.handsFree else { return }
                self.endHandsFree()
                self.finishRecording()
            }
            handsFreeLimit = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.handsFreeMax, execute: limit)
        } else {
            // First short tap: quietly discard and wait to see if a second tap follows.
            lastTap = (mode, Date())
            cancelRecording(quiet: true)
        }
    }

    private func otherKey(_ code: UInt16, whileHeld: Bool) {
        if code == HotkeyMonitor.escape, wake.state == .capturing {
            wake.cancelCapture()
            hud.show("Cancelled", orb: .breathing, autoHide: 0.9)
            return
        }
        guard isRecording else { return }
        if code == HotkeyMonitor.escape {
            endHandsFree()
            cancelRecording(quiet: false)
        } else if code == HotkeyMonitor.chordCode, !handsFree {
            // The Vision shortcut began with a talk key: drop that recording without a word.
            lastTap = nil
            cancelRecording(quiet: true)
        } else if whileHeld && !handsFree {
            // Option+letter or Command+letter: a shortcut, not dictation.
            cancelRecording(quiet: true)
        }
    }

    private func endHandsFree() {
        handsFree = false
        handsFreeLimit?.cancel()
        handsFreeLimit = nil
    }

    // MARK: Recording

    private func startRecording(_ mode: TalkMode) {
        lastEvent = "\(mode.rawValue) key pressed \(Date())"
        guard !isRecording, !isBusy, wake.state != .capturing else { return }
        learner.checkNow()
        targetApp = NSWorkspace.shared.frontmostApplication
        let url = Paths.audioDir.appendingPathComponent(Self.fileStamp() + ".wav")
        do {
            try recorder.start()
        } catch {
            hud.show("Mic error: \(error.localizedDescription)", orb: .shaping, autoHide: 2.5)
            return
        }
        recordingURL = url
        recordingMode = mode
        isRecording = true
        sendable = nil   // a new recording replaces what the two-hand gesture could send
        handDictating = false; sendPending = false; clearPending = false
        syncWake()
        setIcon(recording: true)
        let isAssistant = mode == .assistant
        hud.show(isAssistant ? "\(GWConfig.name) is listening…" : "Listening…", orb: .listening, tint: isAssistant ? .assistant : .plain)
        Sounds.play(isAssistant ? .assistantStart : .start)
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hud.setLevel(self.recorder.level())
        }
        startLivePreview()
        if isAssistant { refreshVault() }
    }

    private func stopRecorder(keep: Bool) -> TimeInterval {
        meterTimer?.invalidate()
        meterTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        previewGeneration += 1
        isRecording = false
        syncWake()
        setIcon(recording: false)
        return recorder.stop(writingTo: keep ? recordingURL : nil)
    }

    /// Words while you talk: every second, transcribe what has been said so far and show the
    /// tail in the pill. Only one request at a time; the final pass after release is the one pasted.
    private func startLivePreview() {
        let generation = previewGeneration
        let live = Paths.dataDir.appendingPathComponent("live.wav")
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isRecording, !self.previewInFlight, self.recorder.elapsed > 1.2,
                  self.recorder.writeWAV(to: live) else { return }
            self.previewInFlight = true
            let vocab = Vocabulary.load()
            Task {
                let text = (try? await self.whisper.transcribe(live, vocabulary: vocab)) ?? ""
                await MainActor.run {
                    self.previewInFlight = false
                    if self.isRecording && self.previewGeneration == generation { self.hud.updateLive(text) }
                }
            }
        }
    }

    private func cancelRecording(quiet: Bool) {
        handDictating = false; sendPending = false; clearPending = false
        guard isRecording else { return }
        _ = stopRecorder(keep: false)
        recordingURL = nil
        if quiet { hud.hide() } else { hud.show("Cancelled", orb: .breathing, autoHide: 0.9) }
    }

    private func finishRecording() {
        guard isRecording, let url = recordingURL else { return }
        let duration = stopRecorder(keep: true)
        recordingURL = nil
        let mode = recordingMode
        Sounds.play(.stop)

        // Very short or very quiet clips make Whisper hallucinate. GoldWare gets a higher bar, since
        // whatever he hears gets filed.
        if duration < (mode == .assistant ? 0.8 : 0.4) || recorder.peakPower < -45 {
            try? FileManager.default.removeItem(at: url)
            hud.show("Didn't hear anything", orb: .breathing, autoHide: 1.2)
            return
        }

        process(url, duration: duration, mode: mode)
    }

    /// Transcribes a finished clip and routes it: pasted as dictation, or handed to GoldWare.
    /// `wake` marks a "Hey GoldWare" clip, whose wake phrase is removed from the words first.
    private func process(_ url: URL, duration: TimeInterval, mode: TalkMode, wake: Bool = false) {
        isBusy = true
        hud.show("Transcribing…", orb: .composing, tint: mode == .assistant ? .assistant : .plain)
        let app = targetApp
        let vocab = Vocabulary.load()

        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let t0 = Date()
                var raw = try await whisper.transcribe(url, vocabulary: vocab)
                if wake { raw = WakeWord.stripWake(raw) }
                let asrMs = Int(Date().timeIntervalSince(t0) * 1000)
                guard !raw.isEmpty else {
                    await MainActor.run { self.hud.show("Didn't catch that", orb: .breathing, autoHide: 1.2) }
                    return
                }
                var record = Dictation(createdAt: Date(), appName: app?.localizedName, appBundle: app?.bundleIdentifier,
                                       durationSec: duration, audioPath: url.path, rawText: raw, finalText: raw,
                                       asrMs: asrMs, cleanupMs: 0, cleanupModel: nil, mode: mode.rawValue)
                if mode == .assistant {
                    try await handleAssistant(raw, record: &record)
                } else {
                    try await handleDictation(raw, app: app, vocab: vocab, record: &record)
                }
            } catch {
                await MainActor.run { self.hud.show(error.localizedDescription, orb: .shaping, autoHide: 3) }
            }
        }
    }

    // MARK: Dictation (Right Option)

    private static let emailApps: Set<String> = ["com.microsoft.Outlook", "com.apple.mail", "com.readdle.smartemail-Mac", "com.superhuman.electron"]
    /// Texting apps: one-line messages there do not end with a period.
    private static let textingApps: Set<String> = ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap",
                                                   "com.meta.endo", "com.facebook.archon", "ru.keepcoder.Telegram", "com.hnc.Discord"]

    private func handleDictation(_ raw: String, app: NSRunningApplication?, vocab: [String], record: inout Dictation) async throws {
        var final = raw
        var historyText = raw
        var inserted: [String] = [], empty: [String] = []
        let asksForItem = library.mightRequestInsert(raw)
        if let item = library.standaloneItem(raw) {
            // The whole clip was a saved item's name, so insert it without asking the cleanup model.
            if item.value.isEmpty {
                final = "[\(item.title)]"
                historyText = final
                empty = [item.title]
            } else {
                final = item.value
                historyText = item.isPrivate ? "[\(item.title)]" : item.value
                inserted = [item.title]
            }
        } else if cleanupEnabled, raw.split(separator: " ").count > 3 || asksForItem {
            await MainActor.run { self.hud.show("Cleaning up…", orb: .weaving) }
            let t1 = Date()
            let isEmail = Self.emailApps.contains(app?.bundleIdentifier ?? "")
            // Saved-item names go to the model only when the words might be asking for one.
            let labels = asksForItem ? library.all.map(\.title) : []
            if let cleaned = try? await cleanup.clean(raw, model: cleanupModel, appName: app?.localizedName,
                                                     vocabulary: vocab, isEmail: isEmail, savedItems: labels) {
                let expansion = library.expand(cleaned, raw: raw)
                final = expansion.text
                historyText = expansion.historyText
                inserted = expansion.inserted
                empty = expansion.empty
                record.cleanupModel = cleanupModel
            }
            record.cleanupMs = Int(Date().timeIntervalSince(t1) * 1000)
        }
        // His most common edit to dictated texts is deleting the final period, so do it for him.
        if Self.textingApps.contains(app?.bundleIdentifier ?? ""), final.hasSuffix("."), !final.hasSuffix("...") {
            final.removeLast()
            if historyText.hasSuffix(".") { historyText.removeLast() }
        }
        record.finalText = historyText
        let saved = record
        let totalMs = record.asrMs + record.cleanupMs
        let warning = empty.first.map { "\($0) is empty, so it was left as a placeholder. Add it with Edit snippets." }
        let added = inserted
        let text = final
        await MainActor.run {
            self.store.insert(saved)
            self.store.writeStats()
            if self.handDictating && self.clearPending {
                // The pinky came while this was still transcribing: it is cleared before it lands.
                self.handDictating = false; self.clearPending = false; self.sendPending = false
                self.hud.show("Cleared", orb: .breathing, tint: .assistant, autoHide: 1.2)
                return
            }
            Paster.paste(text)
            self.rememberPaste("the dictation")
            if self.handDictating, let pid = app?.processIdentifier {
                self.sendable = LastPaste(pid: pid, at: Date(), length: text.count)
                self.typedSince = false
            }
            self.handDictating = false
            if self.sendPending {
                self.sendPending = false
                // Give the paste a moment to land before Return.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.visionSend() }
            }
            self.learner.watch(pasted: text)
            if let warning {
                self.hud.show(warning, orb: .shaping, autoHide: 4)
            } else {
                let with = added.isEmpty ? "" : " with your \(added.joined(separator: ", "))"
                self.hud.show("Pasted\(with) · \(String(format: "%.1f", Double(totalMs) / 1000)) s", orb: .breathing,
                              autoHide: added.isEmpty ? 1.6 : 2.2, action: ("Undo", { [weak self] in self?.performUndo() }))
            }
        }
    }

    // MARK: Assistant (Right Command)

    /// Lock Up, from the spoken phrase or the Vision hand gesture: close every stagnant terminal, keeping
    /// any with an agent mid-task.
    private func lockUp() async {
        await MainActor.run { self.hud.show("Locking up…", orb: .connecting, tint: .assistant) }
        let (closed, kept, error) = await Task.detached { TerminalCommands.lockUp() }.value
        await MainActor.run {
            Sounds.play(error == nil ? .done : .error)
            let keptText = kept == 0 ? "" : ", kept \(kept) working"
            self.hud.show(error ?? "Closed \(closed) terminal\(closed == 1 ? "" : "s")\(keptText)", orb: error == nil ? .breathing : .shaping,
                          tint: .assistant, autoHide: error == nil ? 2.5 : 6)
        }
    }

    /// Clear Out, from the spoken phrase or the Vision hand gesture: close the Hermes terminals nobody wrote in.
    private func clearOut() async {
        await MainActor.run { self.hud.show("Clearing out unused terminals…", orb: .connecting, tint: .assistant) }
        let (closed, left, error) = await Task.detached { TerminalCommands.clearOut() }.value
        await MainActor.run {
            Sounds.play(error == nil ? .done : .error)
            let msg = closed == 0 ? "No unused Hermes terminals" : "Closed \(closed) unused terminal\(closed == 1 ? "" : "s"), \(left) left"
            self.hud.show(error ?? msg, orb: error == nil ? .breathing : .shaping, tint: .assistant, autoHide: error == nil ? 2.5 : 6)
        }
    }

    /// Let's work, from the spoken phrase or the Vision hand gesture: the single handler both call.
    private func openLetsWork() async {
        await MainActor.run { self.hud.show("Opening your workspace…", orb: .connecting, tint: .assistant) }
        let script = await MainActor.run { LetsWork.script() }
        let error = await Task.detached { LetsWork.open(script) }.value
        await MainActor.run {
            Sounds.play(error == nil ? .done : .error)
            self.hud.show(error ?? "Four terminals, one per quadrant", orb: error == nil ? .breathing : .shaping,
                          tint: .assistant, autoHide: error == nil ? 2.5 : 6)
        }
    }

    private func handleAssistant(_ raw: String, record: inout Dictation) async throws {
        if LetsWork.matches(raw) {
            await openLetsWork()
            return
        }
        if TerminalCommands.matchesFinishUp(raw) {
            await MainActor.run { self.hud.show("Asking every Hermes to finish up…", orb: .connecting, tint: .assistant) }
            let (sent, error) = await Task.detached { TerminalCommands.finishUp() }.value
            await MainActor.run {
                Sounds.play(error == nil ? .done : .error)
                self.hud.show(error ?? "Sent to \(sent) Hermes terminal\(sent == 1 ? "" : "s")", orb: error == nil ? .breathing : .shaping,
                              tint: .assistant, autoHide: error == nil ? 2.5 : 6)
            }
            return
        }
        if TerminalCommands.matchesLockUp(raw) {
            await lockUp()
            return
        }
        if TerminalCommands.matchesClearOut(raw) {
            await clearOut()
            return
        }
        // A request to GoldWare needs at least a few real words. Anything shorter is a stray press.
        guard raw.split(separator: " ").count >= 2 else {
            await MainActor.run { self.hud.show("Didn't catch a request. Nothing was filed.", orb: .breathing, tint: .assistant, autoHide: 2) }
            return
        }
        await MainActor.run { self.hud.show("\(GWConfig.name) is thinking…", orb: .connecting, tint: .assistant) }
        let t1 = Date()
        let intent = try await assistant.interpret(raw, model: cleanupModel)
        switch intent.intent {
        case "undo":
            await MainActor.run { self.performUndo() }
            return
        case "agenda":
            let agenda = await taskBoard.agenda()
            await MainActor.run {
                Sounds.play(agenda.error == nil ? .done : .error)
                self.hud.show(agenda.summary, orb: .breathing, tint: .assistant, autoHide: 4)
            }
            return
        case "complete":
            let match = await taskBoard.bestMatch(for: intent.task_query.isEmpty ? raw : intent.task_query)
            await MainActor.run { self.confirmComplete(match, query: intent.task_query) }
            return
        case "vision_on" where Assistant.asksForVision(raw), "vision_off" where Assistant.asksForVision(raw):
            let on = intent.intent == "vision_on"
            await MainActor.run {
                if on != self.vision.modeOn { self.vision.setMode(on) }
                Sounds.play(.done)
                self.hud.show(on ? "Vision Mode on, locked" : "Vision Mode off",
                              orb: .breathing, tint: .assistant, autoHide: 2.5)
            }
            return
        default: break
        }
        let result = await assistant.perform(intent, spoken: raw, store: store)
        record.cleanupMs = Int(Date().timeIntervalSince(t1) * 1000)
        record.cleanupModel = cleanupModel
        record.finalText = intent.intent == "draft" ? intent.draft.body : intent.title
        if intent.intent == "recall" { record.finalText = result.reference }   // keep values out of history
        record.action = result.action
        record.actionRef = result.reference
        record.summary = result.action == "recall" ? "Showed \(result.reference)" : result.summary
        if result.action == "paste" { record.finalText = result.reference }   // keep snippet values out of history
        let saved = record
        let pasteValue = result.pasteValue
        await MainActor.run {
            if let pasteValue { Paster.paste(pasteValue); self.rememberPaste(result.reference) }
            self.store.insert(saved)
            self.store.writeStats()
            switch result.action {
            case "task", "note", "closeout", "queued":
                self.lastUndo = (.capture(requestID: result.reference, title: intent.title), Date())
            case "draft" where result.reference.hasSuffix(".md"):
                if let url = self.assistant.draftURL(result.reference) { self.lastUndo = (.draft(path: url, title: intent.title), Date()) }
            default: break
            }
            let failed = result.action == "failed" || result.action == "skipped"
            Sounds.play(failed ? .error : .done)
            let undoable = ["task", "note", "closeout", "draft", "paste"].contains(result.action) && self.lastUndo != nil
            self.hud.show(result.summary, orb: failed ? .shaping : .breathing, tint: .assistant,
                          autoHide: failed || result.action == "recall" ? 6 : 5,
                          action: undoable ? ("Undo", { [weak self] in self?.performUndo() }) : nil)
        }
    }

    // MARK: Undo

    private func rememberPaste(_ title: String) {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            lastUndo = (.paste(pid: pid, title: title), Date())
        }
    }

    /// What Undo would take back right now, if anything. Pastes can be undone for a minute,
    /// captures and drafts for ten.
    private var undoTitle: String? {
        guard let u = lastUndo else { return nil }
        let age = Date().timeIntervalSince(u.at)
        switch u.action {
        case .paste(_, let t): return age < 60 ? t : nil
        case .capture(_, let t), .draft(_, let t): return age < 600 ? t : nil
        }
    }

    @objc private func performUndo() {
        guard let u = lastUndo, undoTitle != nil else {
            hud.show("Nothing recent to undo", orb: .breathing, tint: .assistant, autoHide: 1.8)
            return
        }
        lastUndo = nil
        switch u.action {
        case .paste(let pid, let title):
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                hud.show("Switch back to that app to undo the paste", orb: .shaping, autoHide: 2.5)
                lastUndo = u
                return
            }
            Paster.sendUndo()
            hud.show("Undid \(title)", orb: .breathing, autoHide: 1.6)
        case .draft(let path, let title):
            // Only a draft still marked drafted is ours to remove; anything edited or sent stays.
            let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            guard text.lowercased().contains("status: drafted") else {
                hud.show("That draft changed since, so it was left alone", orb: .shaping, tint: .assistant, autoHide: 3)
                return
            }
            try? FileManager.default.removeItem(at: path)
            Sounds.play(.stop)
            hud.show("Removed the draft “\(title)”", orb: .breathing, tint: .assistant, autoHide: 2.5)
        case .capture(let requestID, let title):
            // A capture still waiting offline is simply taken out of the queue.
            if store.cancelQueued(requestID: requestID) {
                hud.show("Took back “\(title)” before it reached your tasks", orb: .breathing, tint: .assistant, autoHide: 2.5)
                return
            }
            hud.show("Taking back “\(title)”…", orb: .connecting, tint: .assistant)
            Task {
                var outcome: String? = "Couldn't find it in your tasks"
                if let task = await taskBoard.task(forCapture: requestID) { outcome = await taskBoard.setStatus(task, to: "dropped") }
                let error = outcome
                await MainActor.run {
                    Sounds.play(error == nil ? .stop : .error)
                    self.hud.show(error.map { "Undo failed: \($0)" } ?? "Dropped “\(title)” from your tasks",
                                  orb: error == nil ? .breathing : .shaping, tint: .assistant, autoHide: 3)
                }
            }
        }
    }

    // MARK: Done by voice

    private func confirmComplete(_ match: (BoardTask, Double)?, query: String) {
        guard let (task, _) = match else {
            Sounds.play(.error)
            hud.show("Couldn't find an open task matching “\(query)”", orb: .shaping, tint: .assistant, autoHide: 4)
            return
        }
        Sounds.play(.done)
        let label = task.title
        hud.show("Mark done: \(label)?", orb: .connecting, tint: .assistant, autoHide: 9, action: ("Confirm", { [weak self] in
            guard let self else { return }
            self.hud.show("Marking it done…", orb: .connecting, tint: .assistant)
            Task {
                let error = await self.taskBoard.setStatus(task, to: "done")
                await MainActor.run {
                    Sounds.play(error == nil ? .done : .error)
                    self.hud.show(error.map { "Not marked done: \($0)" } ?? "Done: \(task.title)", orb: error == nil ? .breathing : .shaping,
                                  tint: .assistant, autoHide: error == nil ? 3 : 6)
                }
            }
        }))
    }

    private func flushOutbox(quiet: Bool) {
        guard !store.pendingOutbox().isEmpty else { return }
        Task {
            let sent = await assistant.flushOutbox(store)
            let left = store.pendingOutbox().count
            await MainActor.run {
                if sent > 0 { self.hud.show("Delivered \(sent) saved capture\(sent == 1 ? "" : "s") to your tasks", orb: .breathing, tint: .assistant, autoHide: 2.5) }
                else if !quiet { self.hud.show("The server is still offline (\(left) waiting)", orb: .shaping, autoHide: 2.5) }
                self.writeStatus()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshVault()
        menu.removeAllItems()
        menu.addItem(item("Open \(GWConfig.name) Dashboard", #selector(openDashboard)))
        menu.addItem(.separator())
        menu.addItem(disabled("\(GWConfig.name) Voice: \(statusLine)"))
        menu.addItem(disabled("Hold Right Option: dictate  ·  Hold Right Command: tell \(GWConfig.name)"))
        menu.addItem(disabled("Double-tap either for hands-free  ·  Esc cancels"))
        let stats = store.stats()
        menu.addItem(disabled("\(stats.count) recordings, \(stats.words) words, all stored locally"))
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Grant Accessibility access…", #selector(openAccessibility)))
        }
        let pending = store.pendingOutbox().count
        if pending > 0 {
            menu.addItem(item("⚠︎ \(pending) capture\(pending == 1 ? "" : "s") waiting for the server. Retry", #selector(retryOutbox)))
        }
        menu.addItem(.separator())

        let recentMenu = NSMenu()
        let recent = store.recent(limit: 10, mode: "dictate")
        if recent.isEmpty { recentMenu.addItem(disabled("Nothing yet")) }
        for d in recent {
            let mi = item(Self.clip(d.finalText), #selector(copyRecent(_:)))
            mi.representedObject = d.finalText
            mi.toolTip = "Click to copy. Heard: \(d.rawText)"
            recentMenu.addItem(mi)
        }
        menu.addItem(submenu("Recent dictation (click to copy)", recentMenu))

        let assistantMenu = NSMenu()
        let asks = store.recent(limit: 10, mode: "assistant")
        if asks.isEmpty { assistantMenu.addItem(disabled("Hold Right Command and say “remind me to…”")) }
        for d in asks {
            let icon = ["task": "☐", "note": "✎", "draft": "✉︎", "queued": "…", "failed": "⚠︎"][d.action ?? ""] ?? "•"
            let mi = item("\(icon) \(Self.clip(d.summary ?? d.finalText))", #selector(openAssistantResult(_:)))
            mi.representedObject = d.actionRef
            mi.toolTip = "You said: \(d.rawText)"
            assistantMenu.addItem(mi)
        }
        menu.addItem(submenu("\(GWConfig.name) captures", assistantMenu))
        let undo = item(undoTitle.map { "Undo \(Self.clip($0))" } ?? "Undo", #selector(performUndo))
        undo.isEnabled = undoTitle != nil
        menu.addItem(undo)
        menu.addItem(item("Open Tasks", #selector(openTasks)))
        menu.addItem(item("Open History", #selector(openHistory)))
        menu.addItem(.separator())

        let toggle = item("AI Cleanup", #selector(toggleCleanup))
        toggle.state = cleanupEnabled ? .on : .off
        menu.addItem(toggle)
        let modelMenu = NSMenu()
        for m in (models.isEmpty ? [cleanupModel] : models) {
            let mi = item(m, #selector(chooseModel(_:)))
            mi.representedObject = m
            mi.state = m == cleanupModel ? .on : .off
            modelMenu.addItem(mi)
        }
        menu.addItem(submenu("Model", modelMenu))
        menu.addItem(item("Edit Vocabulary…", #selector(editVocabulary)))
        menu.addItem(item("Edit Snippets…", #selector(editSnippets)))
        menu.addItem(item("Open Data Folder", #selector(openDataFolder)))
        let sounds = item("Sounds", #selector(toggleSounds))
        sounds.state = Sounds.enabled ? .on : .off
        menu.addItem(sounds)
        let heyWake = item("Listen for \u{201C}\(GWConfig.wakePhrase)\u{201D}", #selector(toggleWakeWord))
        heyWake.state = WakeWord.enabled ? .on : .off
        menu.addItem(heyWake)
        // Top level, so it is there for anyone who does not know the ⌘⌥ shortcut.
        let mode = item("\(GWConfig.name) Vision (camera stays on)   ⌘⌥", #selector(toggleVisionMode))
        mode.state = vision.modeOn ? .on : .off
        menu.addItem(mode)
        let visionMenu = NSMenu()
        for (title, style) in [("   Pointer: point, pinch to click, pinch and move to scroll", HandControl.Style.pointer),
                               ("   Quadrants: 1 to 4 fingers dictate into that quarter", .quadrants)] {
            let mi = item(title, #selector(chooseVisionStyle(_:)))
            mi.representedObject = style.rawValue
            mi.state = HandControl.style == style ? .on : .off
            visionMenu.addItem(mi)
        }
        let mirror = item("Hand Mirror (point behind the camera notch)", #selector(toggleMirror))
        mirror.state = VisionController.mirrorEnabled ? .on : .off
        visionMenu.addItem(mirror)
        let face = item(FaceID.menuTitle, #selector(toggleFaceID))
        face.state = FaceID.enabled ? .on : .off
        visionMenu.addItem(face)
        if FaceID.isEnrolled {
            visionMenu.addItem(item("   Set Up Face ID Again…", #selector(setUpFaceID)))
            visionMenu.addItem(item("   Forget My Face", #selector(forgetFace)))
        }
        let speed = NSMenu()
        for (label, base) in [("Relaxed", 0.7), ("Normal", 1.0), ("Fast", 1.4)] {
            let mi = item(label, #selector(chooseHandSpeed(_:)))
            mi.representedObject = base
            mi.state = abs(HandControl.baseSpeed - base) < 0.01 ? .on : .off
            speed.addItem(mi)
        }
        visionMenu.addItem(submenu("Pointer Speed", speed))
        for (title, lines) in [
            ("VISION MODE", ["Press ⌘⌥ together and let go: Vision on or off", "Starts locked until your unlock gesture (gold lock right of the notch opens when unlocked; left: arrow pointer, grid Quadrants)", "Praying hands, held: lock again", "OK sign, held: hide or show the mirror", "Face ID on: only your hands drive (the lock shows a crossed-out person when you are not seen)",
                             "Say \"turn on Vision Mode\" with Right Command",
                             "Say \"Let's work\" with Right Command: a terminal in every quadrant",
                             "Say \"Finish up\": every Hermes wraps up and commits",
                             "Say \"Lock up\": close idle terminals, keep working agents",
                             "Say \"Clear out\": close Hermes terminals you haven't written in",
                             "Point with your index finger: move the pointer like a trackpad",
                             "Thumb far from index: fast. Thumb close: slow and precise", "Pinch and let go: click",
                             "Pinch twice quickly: double-click", "Pinch, hold, and move: scroll (the page follows your hand; let go mid-move to fling)",
                             "Open hand or fist: nothing, rest here",
                             "After a paste, diamond with both hands (index tips touching, thumb tips touching), then let go: press Return to send it",
                             "Pinky alone, held: clear what was just pasted",
                             "Both hands thumb, index, middle; thumbs touch, pull apart: Let's work",
                             "Both hands open, then both fists: Lock Up (close every terminal)",
                             "Both hands open, then one fist: Clear Out (close unused Hermes terminals)",
                             "Four fingers (thumb folded in), held: switch to Quadrants"]),
            ("QUADRANTS", ["Hold up 1 to 4 fingers: pick that quarter of the screen",
                           "1 top left, 2 top right, 3 bottom left, 4 bottom right",
                           "Keep them up: \(GWConfig.name) opens that window's text box and listens",
                           "Lower your hand: \(GWConfig.name) pastes into that text box",
                           "After a paste, diamond with both hands, then let go: press Return to send it",
                           "Pinky alone, held: clear what was just pasted",
                           "Switching in snaps every window into the corners",
                           "Holding a count brings that corner's window to the front",
                           "Fist: rest. Open hand (all five spread), held: back to the pointer"]),
            ("SCAN (mirror or Vision Mode)", ["Hold a card, receipt, or page still until the outline closes",
                                              "Thumbs up: file it as a task", "2 fingers: copy what it read",
                                              "Fist: discard"]),
        ] {
            visionMenu.addItem(.separator())
            visionMenu.addItem(disabled(title))
            for line in lines { visionMenu.addItem(disabled("   " + line)) }
        }
        menu.addItem(submenu("\(GWConfig.name) Vision Settings", visionMenu))
        let pill = item("Always Show Indicator", #selector(toggleIndicator))
        pill.state = hud.alwaysVisible ? .on : .off
        menu.addItem(pill)
        let login = item("Open at Login", #selector(toggleLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.title = "Open at Login (approve in System Settings)"; login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit \(GWConfig.name) Voice", #selector(quit), key: "q"))
    }

    private static func clip(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 70 ? String(one.prefix(70)) + "…" : one
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { Paster.copy(text) }
    }

    /// Drafts open in the editor; tasks and notes open the dashboard where they landed.
    @objc private func openAssistantResult(_ sender: NSMenuItem) {
        if let ref = sender.representedObject as? String, ref.hasSuffix(".md"), let url = assistant.draftURL(ref) {
            NSWorkspace.shared.open(url)
        } else {
            openTasks()
        }
    }

    @objc private func openTasks() {
        dashboard.show(tab: "dashboard")
    }

    @objc private func retryOutbox() {
        flushOutbox(quiet: false)
    }

    @objc private func toggleVisionMode() {
        vision.setMode(!vision.modeOn)
        announceVisionMode()
    }

    @objc private func chooseVisionStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = HandControl.Style(rawValue: raw) else { return }
        vision.setMode(true, style: style)
        announceVisionMode()
    }

    private func announceVisionMode() {
        let text = !vision.modeOn ? "Vision Mode off. Camera is off."
            : HandControl.style == .quadrants ? "Quadrants on. Hold up 1 to 4 fingers to dictate into that quarter of the screen."
            : "Vision Mode on. Point to move, pinch to click, pinch and move to scroll."
        hud.show(text, orb: .breathing, tint: .assistant, autoHide: 2.5)
    }

    @objc private func chooseHandSpeed(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { HandControl.baseSpeed = v }
    }

    @objc private func toggleMirror() {
        VisionController.mirrorEnabled.toggle()
    }

    /// Turning Face ID on with no face saved runs setup first; it switches on only once setup succeeds.
    @objc private func toggleFaceID() {
        if FaceID.enabled { FaceID.enabled = false; vision.camera.reloadFace(); hud.show("Face ID is off. Any hand drives Vision.", orb: .breathing, tint: .assistant, autoHide: 3); return }
        if FaceID.isEnrolled { FaceID.enabled = true; vision.camera.reloadFace(); hud.show("Face ID is on. Only your hands drive Vision.", orb: .breathing, tint: .assistant, autoHide: 3) }
        else { vision.setUpFaceID() }
    }

    @objc private func setUpFaceID() { vision.setUpFaceID() }
    @objc private func forgetFace() { vision.forgetFace() }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
        if cleanupEnabled { Task { await cleanup.warm(model: cleanupModel) } }
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        cleanupModel = m
        hud.show("Using \(m)", orb: .working, autoHide: 2)
        if cleanupEnabled { Task { await cleanup.warm(model: m) } }
    }

    @objc private func openHistory() {
        HistoryPage.write(store.recent(limit: 500))
        historyWindow.show()
    }

    @objc private func editVocabulary() {
        _ = Vocabulary.load()
        NSWorkspace.shared.open(Paths.vocabulary)
    }

    /// The same switch as the control center's; turning it on asks for Speech Recognition the first time.
    @objc private func toggleWakeWord() {
        let on = !WakeWord.enabled
        setWakeWord(on)
        if !on { hud.show("\(GWConfig.wakePhrase) off", orb: .breathing, tint: .assistant, autoHide: 1.5) }
        else {
            // Confirm once the permission answer is in, so a declined prompt does not read as "on".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard WakeWord.enabled else { return }
                self?.hud.show("\(GWConfig.wakePhrase) is on. Say \u{201C}\(GWConfig.wakePhrase)\u{201D} and your request.", orb: .breathing, tint: .assistant, autoHide: 2.5)
            }
        }
    }

    @objc private func toggleSounds() {
        Sounds.enabled.toggle()
    }

    @objc private func toggleIndicator() {
        hud.alwaysVisible.toggle()
        UserDefaults.standard.set(hud.alwaysVisible, forKey: "indicatorAlwaysVisible")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            hud.show("Could not change login item: \(error.localizedDescription)", orb: .shaping, autoHide: 3)
        }
    }

    @objc private func editSnippets() {
        Library.seedSnippetsIfNeeded()
        NSWorkspace.shared.open([Library.snippetsFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(Paths.dataDir)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Hey GoldWare

    private func configureWake() {
        wake.onWake = { [weak self] in
            guard let self else { return }
            self.targetApp = NSWorkspace.shared.frontmostApplication
            self.recordingMode = .assistant
            self.setIcon(recording: true)
            Sounds.play(.assistantStart)
            self.hud.show("\(GWConfig.name) is listening…", orb: .listening, tint: .assistant)
            self.refreshVault()
        }
        wake.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        wake.onNothing = { [weak self] in
            self?.setIcon(recording: false)
            self?.hud.show("Didn't hear a request", orb: .breathing, autoHide: 1.2)
            self?.syncWake()
        }
        wake.onRequest = { [weak self] url, duration, peak in
            guard let self else { return }
            self.setIcon(recording: false)
            Sounds.play(.stop)
            if peak < -45 {
                try? FileManager.default.removeItem(at: url)
                self.hud.show("Didn't hear anything", orb: .breathing, autoHide: 1.2)
                self.syncWake()
                return
            }
            self.process(url, duration: duration, mode: .assistant, wake: true)
        }
        wake.onError = { [weak self] text in
            self?.setIcon(recording: false)
            self?.hud.show(text, orb: .shaping, autoHide: 3)
        }
        if WakeWord.enabled { setWakeWord(true) }
    }

    /// The control center switch. Asks for speech recognition the first time.
    private func setWakeWord(_ on: Bool) {
        guard on else {
            WakeWord.enabled = false
            wake.setActive(false)
            return
        }
        WakeWord.authorize { [weak self] granted in
            guard let self else { return }
            guard granted else {
                WakeWord.enabled = false
                self.hud.show("\(GWConfig.wakePhrase) needs Speech Recognition access in System Settings > Privacy", orb: .shaping, autoHide: 4)
                return
            }
            WakeWord.enabled = true
            self.syncWake()
        }
    }

    /// Listens for "Hey GoldWare" only while the switch is on and nothing else is using the microphone
    /// or thinking: the talk keys and a fist pause it, and it resumes when they finish.
    private func syncWake() {
        wake.setActive(WakeWord.enabled && !isRecording && !isBusy)
    }

    /// A Quadrant dictation works like holding Right Option: dictate into the window it picked.
    /// Only a recording the hand started is finished by the hand, so the keys are never cut off.
    private var handRecording = false
    /// The last hand-started dictation that pasted: which app, when, and how long. Only that paste can be
    /// sent or cleared, and only while it is still the last thing typed there.
    struct LastPaste { var pid: pid_t; var at: Date; var length: Int }
    private var sendable: LastPaste?
    /// A real key or click since that paste: the box may hold something else now, so neither gesture acts.
    private var typedSince = false
    private var handDictating = false
    private var sendPending = false   // the gesture came while that dictation was still transcribing
    private var clearPending = false  // the pinky came while it was still transcribing

    /// Whether the send or clear gesture may act now (pure, for the self-test).
    enum SendDecision: Equatable { case send, wait, nothing, notInFront, typedSince }
    static func sendDecision(sendable: LastPaste?, typedSince: Bool = false, transcribing: Bool, front: pid_t?, now: Date) -> SendDecision {
        guard let s = sendable else { return transcribing ? .wait : .nothing }
        guard now.timeIntervalSince(s.at) < 120 else { return .nothing }
        guard !typedSince else { return .typedSince }
        return front == s.pid ? .send : .notInFront
    }

    private func visionDictate(_ start: Bool) {
        if start {
            guard !isRecording, !isBusy, wake.state != .capturing else { return }
            startRecording(.dictate)   // records the app in front; Quadrant Dictation brings its window forward first
            handRecording = isRecording
            handDictating = isRecording
        } else if handRecording {
            handRecording = false
            if isRecording && recordingMode == .dictate && !handsFree { finishRecording() }
        }
    }

    /// The two-hand gesture in Quadrants: press Return in the window the last hand dictation pasted into,
    /// so the message sends. Only within two minutes of that paste, only once, and only if that app is
    /// still in front, so the gesture never presses Return somewhere it was not meant for.
    private func visionSend() {
        switch Self.sendDecision(sendable: sendable, typedSince: typedSince, transcribing: handDictating && isBusy,
                                 front: NSWorkspace.shared.frontmostApplication?.processIdentifier, now: Date()) {
        case .wait:
            sendPending = true   // sent as soon as the paste lands
            hud.show("Sending once it pastes", orb: .composing, tint: .assistant, autoHide: 1.5)
        case .nothing:
            hud.show("Nothing to send", orb: .breathing, tint: .assistant, autoHide: 1.2)
        case .notInFront:
            sendable = nil
            hud.show("Not sent: that window is no longer in front", orb: .shaping, autoHide: 2)
        case .typedSince:
            sendable = nil
            hud.show("Not sent: something was typed or clicked after it", orb: .shaping, autoHide: 2)
        case .send:
            sendable = nil
            Paster.pressReturn()
            Sounds.play(.done)
            hud.show("Sent", orb: .breathing, tint: .assistant, autoHide: 1.2)
        }
    }

    /// The pinky, held: delete the last hand dictation's paste (Backspace once per character), under the
    /// same rules as sending. Made while it is still transcribing, the paste is dropped instead.
    private func visionClear() {
        switch Self.sendDecision(sendable: sendable, typedSince: typedSince, transcribing: handDictating && isBusy,
                                 front: NSWorkspace.shared.frontmostApplication?.processIdentifier, now: Date()) {
        case .wait:
            clearPending = true; sendPending = false
            hud.show("Clearing it before it pastes", orb: .composing, tint: .assistant, autoHide: 1.5)
        case .nothing:
            hud.show("Nothing to clear", orb: .breathing, tint: .assistant, autoHide: 1.2)
        case .notInFront:
            sendable = nil
            hud.show("Not cleared: that window is no longer in front", orb: .shaping, autoHide: 2)
        case .typedSince:
            sendable = nil
            hud.show("Not cleared: something was typed or clicked after it", orb: .shaping, autoHide: 2)
        case .send:
            let n = sendable?.length ?? 0
            sendable = nil
            Paster.deleteBack(n)
            Sounds.play(.done)
            hud.show("Cleared", orb: .breathing, tint: .assistant, autoHide: 1.2)
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            controlCenter.close()
            classicMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else {
            controlCenter.toggle(from: sender)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func setIcon(recording: Bool) {
        if !recording, let assistant = Mascot.menuBarIcon() {
            statusItem.button?.image = assistant
            return
        }
        let name = recording ? "mic.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "\(GWConfig.name) Voice")
        image?.isTemplate = !recording
        let color: NSColor = recordingMode == .assistant ? NSColor(red: 0.82, green: 0.67, blue: 0.37, alpha: 1) : .systemRed
        statusItem.button?.image = recording ? image?.withSymbolConfiguration(.init(paletteColors: [color])) : image
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return f.string(from: Date())
    }
}
