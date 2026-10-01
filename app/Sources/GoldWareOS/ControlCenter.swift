import AppKit
import Darwin

// MARK: - Live system readings

/// CPU and memory, read straight from the kernel (no subprocesses): cheap enough to sample every second.
final class SystemStats {
    struct Sample {
        var cpu: Double; var memUsed: Double; var memTotal: Double; var pressure: Double
        var user = 0.0, system = 0.0                       // shares of all cores, 0...1
        var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0, swapUsed = 0.0   // bytes
        var load: [Double] = []                            // 1, 5, 15 minute load averages
    }

    private var lastTicks: (user: UInt64, sys: UInt64, busy: UInt64, total: UInt64)?

    func sample() -> Sample {
        let c = cpuLoad(), m = memory()
        var s = Sample(cpu: c.busy, memUsed: m.app + m.wired + m.compressed, memTotal: Double(ProcessInfo.processInfo.physicalMemory),
                       pressure: memoryPressure())
        (s.user, s.system) = (c.user, c.system)
        (s.app, s.wired, s.compressed, s.cached) = (m.app, m.wired, m.compressed, m.cached)
        s.swapUsed = swapUsed()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.load = load }
        return s
    }

    /// Shares of all cores busy (and user, system) since the last call, 0...1.
    private func cpuLoad() -> (busy: Double, user: Double, system: Double) {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return (0, 0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0, users: UInt64 = 0, syss: UInt64 = 0
        for i in 0..<Int(cpus) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
            users += user + nice; syss += sys
        }
        defer { lastTicks = (users, syss, busy, total) }
        guard let last = lastTicks, total > last.total else { return (0, 0, 0) }
        let span = Double(total - last.total)
        return (Double(busy &- last.busy) / span, Double(users &- last.user) / span, Double(syss &- last.sys) / span)
    }

    /// Bytes the way Activity Monitor splits them; "Memory Used" is app + wired + compressed.
    private func memory() -> (app: Double, wired: Double, compressed: Double, cached: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return (0, 0, 0, 0) }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app * page, Double(stats.wire_count) * page, Double(stats.compressor_page_count) * page,
                (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page)
    }

    private func swapUsed() -> Double {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Double(swap.xsu_used) : 0
    }

    /// The kernel's memory pressure level: 1 normal, 2 warning, 4 critical.
    private func memoryPressure() -> Double {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return Double(level)
    }
}

/// The busiest apps and processes, from `ps` (only while a gauge's detail is open, every 2 s).
enum TopProcesses {
    struct Proc: Equatable { var pid: Int; var name: String; var cpu: Double; var mem: Double }

    /// Lines of `ps -Aceo pid=,pcpu=,rss=,comm=`: rss is in KB, and names may contain spaces.
    static func parse(_ text: String) -> [Proc] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int(f[0]), let cpu = Double(f[1]), let rss = Double(f[2]) else { return nil }
            return Proc(pid: pid, name: String(f[3]), cpu: cpu, mem: rss * 1024)
        }
    }

    static func read() -> [Proc] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func top(_ procs: [Proc], by detail: ControlCenterView.Detail, count: Int = 5) -> [Proc] {
        Array(procs.sorted { detail == .cpu ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(count))
    }
}

/// Apple's own speed test (`networkQuality`, built into macOS): download, upload, and responsiveness.
enum SpeedTest {
    struct Result { var down: Double; var up: Double; var ping: Double }

    static func run() async -> Result? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            p.arguments = ["-c", "-M", "15"]   // -M caps the run at 15 s
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(returning: nil); return }
            // Read before waiting, so a full pipe can never stall the test; a stuck run is killed at 25 s.
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let down = j["dl_throughput"] as? Double else { cont.resume(returning: nil); return }
                cont.resume(returning: Result(down: down / 1e6, up: (j["ul_throughput"] as? Double ?? 0) / 1e6,
                                              ping: j["base_rtt"] as? Double ?? 0))
            }
        }
    }
}

// MARK: - The panel

/// GoldWare's control center: drops from the menu bar mascot. Live CPU and memory, a Wi-Fi speed test,
/// GoldWare Vision switches, and shortcuts. Right-click the mascot for the full classic menu.
final class ControlCenter {
    struct Actions {
        var openDashboard: () -> Void = {}
        var openTasks: () -> Void = {}
        var openHistory: () -> Void = {}
        var openVisionGuide: () -> Void = {}
        var undo: () -> Void = {}
        var undoTitle: () -> String? = { nil }
        var visionMode: () -> Bool = { false }
        var setVisionMode: (Bool) -> Void = { _ in }
        var quadrants: () -> Bool = { false }
        var setQuadrants: (Bool) -> Void = { _ in }
        var mirror: () -> Bool = { true }
        var setMirror: (Bool) -> Void = { _ in }
        var wakeWord: () -> Bool = { false }
        var setWakeWord: (Bool) -> Void = { _ in }
        var status: () -> String = { "" }
        var quit: () -> Void = {}
        var agenda: () async -> Agenda = { Agenda() }
        var restartWhisper: () -> Void = {}
    }

    var actions = Actions()
    private var panel: NSPanel?
    private let view = ControlCenterView()
    private let stats = SystemStats()
    private var timer: Timer?
    private var spin: Timer?
    private var monitors: [Any] = []
    var isShown: Bool { panel?.isVisible == true }

    init() {
        view.center = self
        _ = stats.sample()   // prime the CPU delta
    }

    func toggle(from button: NSStatusBarButton?) {
        isShown ? close() : show(from: button)
    }

    func show(from button: NSStatusBarButton?) {
        let p = panel ?? make()
        panel = p
        view.refreshState()
        tick()
        refreshUsage()
        refreshWork(force: true)
        let size = view.intrinsicContentSize
        var origin = NSPoint(x: 0, y: 0)
        if let b = button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            let screen = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: min(max(r.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8),
                             y: r.minY - size.height - 6)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; p.animator().alphaValue = 1 }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        // Close on a click elsewhere or Escape.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.close() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 53: self.close()
            case 48: self.view.setPage(self.view.page == .controls ? .work : .controls)          // Tab
            case 123 where self.view.page == .work: self.view.stepTab(-1)                         // Left
            case 124 where self.view.page == .work: self.view.stepTab(1)                          // Right
            default: return e
            }
            return nil
        }) { monitors.append(l) }
    }

    func close() {
        if view.detail != nil { view.detail = nil; view.procs = []; panel.map { resize($0, animate: false) } }
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    /// Once a second while open: fresh stats, and the switches and undo re-read in case voice changed them.
    private func tick() {
        view.push(stats.sample())
        view.refreshState()
        refreshProcesses()
        if view.page == .work { refreshWork() }
    }

    /// For --render-control-center --work: the same read, done synchronously.
    func loadWorkForDebug() {
        let a = actions
        let done = DispatchSemaphore(value: 0)
        var snap = WorkSnapshot()
        Task.detached {
            let agenda = await a.agenda()
            snap = WorkData.load(agenda: agenda, root: VaultContext.resolveRoot())
            done.signal()
        }
        done.wait()
        view.work = snap
    }

    /// The Work page: read on open, then every 5 s while the panel is open, off the main thread.
    private var workAt: Date?
    private var workBusy = false
    func refreshWork(force: Bool = false) {
        guard !workBusy, force || workAt.map({ Date().timeIntervalSince($0) >= 5 }) ?? true else { return }
        workBusy = true
        workAt = Date()
        let a = actions
        let root = VaultContext.resolveRoot()
        Task.detached(priority: .utility) {
            let agenda = await a.agenda()
            let snap = WorkData.load(agenda: agenda, root: root)
            await MainActor.run {
                self.workBusy = false
                self.view.work = snap
                self.view.needsDisplay = true
            }
        }
    }

    /// Click a gauge: its detail drops down under the gauges; click it again (or the other one) to switch.
    func toggleDetail(_ d: ControlCenterView.Detail) {
        view.detail = view.detail == d ? nil : d
        procsAt = nil
        refreshProcesses()
        panel.map { resize($0, animate: true) }
        view.needsDisplay = true
    }

    private var procsAt: Date?
    private var procsBusy = false
    private func refreshProcesses() {
        guard view.detail != nil, !procsBusy, procsAt.map({ Date().timeIntervalSince($0) >= 2 }) ?? true else { return }
        procsBusy = true
        procsAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let procs = TopProcesses.read()
            DispatchQueue.main.async {
                self.procsBusy = false
                guard self.view.detail != nil else { return }
                self.view.procs = procs
                self.view.needsDisplay = true
            }
        }
    }

    /// After a page switch changes the height (a gauge dropdown only lives on the controls page).
    func relayout() { panel.map { resize($0, animate: true) } }

    /// Grow or shrink downward: the top edge stays under the menu bar.
    private func resize(_ p: NSPanel, animate: Bool) {
        let size = view.intrinsicContentSize
        var f = p.frame
        f.origin.y = f.maxY - size.height
        f.size = size
        p.setFrame(f, display: true, animate: animate)
    }

    /// For --render-control-center: a laid-out view with real stats.
    static let slideFreeze = ControlCenterView.pageDuration * 0.25
    func debugView(speed: Bool, detail: ControlCenterView.Detail? = nil, work: WorkTab? = nil) -> ControlCenterView {
        view.detail = detail
        view.page = work == nil ? .controls : .work
        if let work { view.workTab = work; view.expandedRepo = view.work.repo.first?.title }
        // --mid-slide: freeze the page switch halfway, to check both pages clip cleanly while moving.
        if CommandLine.arguments.contains("--mid-slide") {
            view.pageAnim = (work == nil ? .work : .controls, CACurrentMediaTime() - Self.slideFreeze)
            view.tabAnim = nil
        }
        if detail != nil { view.procs = TopProcesses.read() }
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        actions.status = { "Ready" }
        actions.undoTitle = { "Renew the domain" }
        view.refreshState()
        for _ in 0..<8 { usleep(150_000); tick() }
        if speed { view.speed = SpeedTest.Result(down: 64.1, up: 17.0, ping: 98.5) }
        let now = Date()
        view.plans = [
            .init(name: "Claude", windows: [.init(label: "5H", percent: 26, resets: now + 3 * 3600),
                                            .init(label: "WEEK", percent: 84, resets: now + 3 * 86_400)]),
            .init(name: "Codex", windows: [.init(label: "WEEK", percent: 40, resets: now + 4 * 86_400)])]
        return view
    }

    /// Plan limits, fetched when the panel opens and at most every 2 minutes.
    private var usageFetched: Date?
    func refreshUsage() {
        if let t = usageFetched, Date().timeIntervalSince(t) < 120 { return }
        usageFetched = Date()
        Task {
            let plans = await PlanUsage.fetchAll()
            await MainActor.run {
                self.view.plans = plans
                if plans.contains(where: { $0.error != nil }) { self.usageFetched = nil }   // retry on next open
                self.view.needsDisplay = true
            }
        }
    }

    func runSpeedTest() {
        guard !view.speedRunning else { return }
        view.speedRunning = true
        view.speed = nil
        view.needsDisplay = true
        // Keep the spinner turning between the once-a-second stat ticks.
        spin = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.view.needsDisplay = true }
        RunLoop.main.add(spin!, forMode: .common)
        Task {
            let r = await SpeedTest.run()
            await MainActor.run {
                self.spin?.invalidate(); self.spin = nil
                self.view.speedRunning = false
                self.view.speed = r
                self.view.speedFailed = r == nil
                self.view.needsDisplay = true
            }
        }
    }

    private func make() -> NSPanel {
        let p = CenterPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.contentView = view
        return p
    }
}

private final class CenterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Everything drawn by hand with the dashboard tokens, like the HUD card.
final class ControlCenterView: NSView {
    weak var center: ControlCenter?
    var speed: SpeedTest.Result?
    var speedRunning = false
    var speedFailed = false
    var plans: [PlanUsage.Plan] = []
    enum Detail { case cpu, memory }
    var detail: Detail?
    var procs: [TopProcesses.Proc] = []
    static let detailHeight: CGFloat = 208
    enum Page: String { case controls, work }
    var page = Page(rawValue: UserDefaults.standard.string(forKey: "controlCenterPage") ?? "") ?? .controls
    var workTab = WorkTab(rawValue: UserDefaults.standard.integer(forKey: "controlCenterWorkTab")) ?? .needs
    var work = WorkSnapshot()
    var expandedRepo: String?
    /// Motion: the page slide, the tab pill, and the content fade, each with its start time.
    var pageAnim: (from: Page, start: CFTimeInterval)?
    var tabAnim: (from: NSRect, start: CFTimeInterval)?
    var tabRect: NSRect?
    var animTimer: Timer?
    private var cpu: [Double] = []
    private var mem: [Double] = []
    private var last: SystemStats.Sample?
    var buttons: [(rect: NSRect, action: () -> Void)] = []
    var hover: NSRect?
    private var tracking: NSTrackingArea?
    private var visionOn = false, quadrantsOn = false, mirrorOn = true, wakeOn = false, status = ""
    var undoTitle: String?

    static let width: CGFloat = 340
    let pad: CGFloat = 18
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: 744 + (detail == nil || page == .work ? 0 : Self.detailHeight)) }

    func refreshState() {
        guard let a = center?.actions else { return }
        visionOn = a.visionMode()
        quadrantsOn = visionOn && a.quadrants()
        mirrorOn = a.mirror()
        wakeOn = a.wakeWord()
        undoTitle = a.undoTitle()
        status = a.status()
        needsDisplay = true
    }

    // VoiceOver: the panel is custom-drawn, so describe it as one group with a readable summary.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        var parts = ["\(GWConfig.name) control center"]
        if let s = last {
            parts.append("CPU \(Int((s.cpu * 100).rounded())) percent")
            parts.append(String(format: "memory %.1f of %.0f gigabytes", s.memUsed / 1_073_741_824, s.memTotal / 1_073_741_824))
        }
        if let d = detail {
            parts.append("top by \(d == .cpu ? "CPU" : "memory"): " + TopProcesses.top(procs, by: d).map(\.name).joined(separator: ", "))
        }
        if let s = speed { parts.append(String(format: "download %.0f, upload %.0f megabits, ping %.0f milliseconds", s.down, s.up, s.ping)) }
        for p in plans {
            parts.append(p.error.map { "\(p.name) \($0)" } ?? "\(p.name) " + p.windows.map { "\($0.label == "5H" ? "5 hour" : $0.label.lowercased()) \(Int($0.percent.rounded())) percent used" }.joined(separator: ", "))
        }
        parts.append("page \(page.rawValue)")
        if page == .work {
            parts.append(workTab.label + ": " + work.rows(workTab).prefix(6).map { "\($0.title), \($0.meta.lowercased())" }.joined(separator: "; "))
        }
        parts.append("\(GWConfig.wakePhrase) \(wakeOn ? "on" : "off")")
        parts.append("Vision Mode \(visionOn && !quadrantsOn ? "on" : "off"), Quadrant Dictation \(quadrantsOn ? "on" : "off"), Hand Mirror \(mirrorOn ? "on" : "off")")
        return parts.joined(separator: ", ")
    }

    func push(_ s: SystemStats.Sample) {
        last = s
        cpu.append(s.cpu); mem.append(s.memUsed / max(1, s.memTotal))
        if cpu.count > 60 { cpu.removeFirst(); mem.removeFirst() }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = buttons.first { $0.rect.contains(p) }?.rect
        if h != hover { hover = h; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        buttons.first { $0.rect.contains(p) }?.action()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        buttons.removeAll()
        let w = bounds.width
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        Theme.bg.setFill(); body.fill()
        Theme.border.setStroke(); body.lineWidth = 1; body.stroke()
        // Gold hairline across the top, like the dashboard header.
        Theme.goldGradient.draw(in: NSRect(x: 24, y: 0.5, width: w - 48, height: 1), angle: 0)

        var y: CGFloat = 16
        Mascot.draw(in: Mascot.rect(height: 22, at: NSPoint(x: pad - 2, y: y)))
        Theme.draw(GWConfig.name, at: NSPoint(x: pad + 28, y: y - 5), font: Self.nameFont(), color: Theme.text, kern: -0.2)
        drawPageSwitch(y: y)
        // Status: a green dot when ready; otherwise gold, with a short word (full text in VoiceOver).
        let ready = status == "Ready"
        let word: String
        switch status.lowercased() {
        case "ready": word = "READY"
        case let s where s.hasPrefix("loading") || s.hasPrefix("starting"): word = "STARTING"
        default: word = "CHECK"      // denied or failed: the right-click menu has the full line
        }
        let sf = Theme.mono(9.5, "Regular")
        let ww = Theme.size(word, font: sf, kern: 0.6).width
        let dot = NSBezierPath(ovalIn: NSRect(x: w - pad - ww - 10, y: y + 8, width: 6, height: 6))
        (ready ? Theme.green : Theme.gold).setFill(); dot.fill()
        Theme.draw(word, at: NSPoint(x: w - pad - ww, y: y + 4), font: sf, color: ready ? Theme.textMuted : Theme.gold, kern: 0.6)
        y += 42
        let contentTop = y
        let headerButtons = buttons.count
        // Pages slide sideways when switched; the header and footer stay put.
        let slide = pageProgress()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: contentTop, width: w, height: bounds.height - contentTop - 30)).addClip()
        if let a = pageAnim, slide < 1 {
            let dir: CGFloat = page == .work ? 1 : -1
            drawPage(a.from, top: contentTop, dx: -dir * w * slide, alpha: 1 - slide)
            drawPage(page, top: contentTop, dx: dir * w * (1 - slide), alpha: slide)
            buttons.removeSubrange(headerButtons...)   // nothing is clickable mid-slide
        } else {
            drawPage(page, top: contentTop, dx: 0, alpha: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        drawFooter()
    }

    private func drawPage(_ p: Page, top: CGFloat, dx: CGFloat, alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: dx, y: 0)
        ctx.setAlpha(alpha)
        if p == .controls { drawControls(top: top) } else { drawWork(top: top) }
        ctx.restoreGState()
    }

    private func drawControls(top: CGFloat) {
        let w = bounds.width
        var y = top
        // System
        Theme.drawSectionTitle("System", at: NSPoint(x: pad, y: y))
        y += 22
        let cardW = (w - pad * 2 - 10) / 2
        drawGauge(NSRect(x: pad, y: y, width: cardW, height: 92), title: "CPU",
                  value: last.map { "\(Int(($0.cpu * 100).rounded()))%" } ?? "…", sub: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                  series: cpu, selected: detail == .cpu) { [weak self] in self?.center?.toggleDetail(.cpu) }
        let pressure = last.map { $0.pressure >= 4 ? "pressure critical" : $0.pressure >= 2 ? "pressure warning" : "pressure normal" } ?? ""
        drawGauge(NSRect(x: pad + cardW + 10, y: y, width: cardW, height: 92), title: "MEMORY",
                  value: last.map { String(format: "%.1f GB", $0.memUsed / 1_073_741_824) } ?? "…",
                  sub: last.map { String(format: "of %.0f GB · %@", $0.memTotal / 1_073_741_824, pressure) } ?? "",
                  series: mem, warn: (last?.pressure ?? 1) >= 2, selected: detail == .memory) { [weak self] in self?.center?.toggleDetail(.memory) }
        y += 104
        if let d = detail {
            drawDetail(NSRect(x: pad, y: y - 4, width: w - pad * 2, height: Self.detailHeight - 12), d)
            y += Self.detailHeight
        }

        // Network
        Theme.drawSectionTitle("Wi-Fi speed", at: NSPoint(x: pad, y: y))
        y += 22
        let net = NSRect(x: pad, y: y, width: w - pad * 2, height: 76)
        drawCard(net)
        if speedRunning {
            Theme.draw("Testing…", at: NSPoint(x: net.minX + 14, y: net.minY + 14), font: Theme.display(20, italic: true), color: Theme.text)
            Theme.draw("Apple's networkQuality, about 15 seconds", at: NSPoint(x: net.minX + 14, y: net.minY + 44),
                       font: Theme.sans(11.5), color: Theme.textMuted)
            drawSpinner(center: NSPoint(x: net.maxX - 28, y: net.midY))
        } else if let s = speed {
            let cols: [(String, String, String)] = [
                ("DOWN", String(format: "%.0f", s.down), "Mbps"), ("UP", String(format: "%.0f", s.up), "Mbps"),
                ("PING", String(format: "%.0f", s.ping), "ms")]
            let cw = (net.width - 28 - 70) / 3
            for (i, c) in cols.enumerated() {
                let x = net.minX + 14 + CGFloat(i) * cw
                Theme.draw(c.0, at: NSPoint(x: x, y: net.minY + 12), font: Theme.sans(9.5, "Medium"), color: Theme.textMuted, kern: 1.6)
                let v = Theme.draw(c.1, at: NSPoint(x: x, y: net.minY + 26), font: Theme.display(28), color: i == 0 ? Theme.goldHi : Theme.text)
                Theme.draw(c.2, at: NSPoint(x: x + v.width + 3, y: net.minY + 40), font: Theme.sans(10.5), color: Theme.textMuted)
            }
            button(NSRect(x: net.maxX - 70, y: net.minY + 24, width: 56, height: 28), "Again", gold: false) { [weak self] in self?.center?.runSpeedTest() }
        } else {
            Theme.draw(speedFailed ? "The test couldn't finish" : "How fast is this connection?", at: NSPoint(x: net.minX + 14, y: net.minY + 14),
                       font: Theme.display(18, italic: true), color: speedFailed ? Theme.red : Theme.text)
            Theme.draw("Download, upload, and ping", at: NSPoint(x: net.minX + 14, y: net.minY + 44), font: Theme.sans(11.5), color: Theme.textMuted)
            button(NSRect(x: net.maxX - 88, y: net.minY + 24, width: 74, height: 28), "Run test", gold: true) { [weak self] in self?.center?.runSpeedTest() }
        }
        y += 88

        // Plan limits: one clickable row per plan, opening its usage page.
        Theme.drawSectionTitle("Plan limits", at: NSPoint(x: pad, y: y))
        y += 22
        let lim = NSRect(x: pad, y: y, width: w - pad * 2, height: 108)
        drawCard(lim)
        if plans.isEmpty {
            Theme.draw("Checking…", at: NSPoint(x: lim.minX + 14, y: lim.minY + 14), font: Theme.display(18, italic: true), color: Theme.text)
            Theme.draw("Claude and Codex subscription usage", at: NSPoint(x: lim.minX + 14, y: lim.minY + 44), font: Theme.sans(11.5), color: Theme.textMuted)
        }
        for (i, plan) in plans.prefix(2).enumerated() {
            let row = NSRect(x: lim.minX + 4, y: lim.minY + 6 + CGFloat(i) * 48, width: lim.width - 8, height: 46)
            planRow(row, plan, url: plan.name == "Claude" ? PlanUsage.claudePage : PlanUsage.codexPage)
        }
        y += 120

        // Voice
        Theme.drawSectionTitle("\(GWConfig.name) Voice", at: NSPoint(x: pad, y: y))
        y += 22
        y = toggleRow(y, GWConfig.wakePhrase, "Say it to start a request · on this Mac only", on: wakeOn) { [weak self] in
            guard let self, let a = self.center?.actions else { return }
            a.setWakeWord(!self.wakeOn)
            // Permission is asked asynchronously; re-read shortly so the switch shows the outcome.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshState() }
            self.refreshState()
        }
        y += 8

        // GoldWare Vision
        Theme.drawSectionTitle("\(GWConfig.name) Vision", at: NSPoint(x: pad, y: y))
        let guide = "Commands"
        let gf = Theme.sans(11, "Medium")
        link(NSPoint(x: bounds.width - pad - Theme.size(guide, font: gf).width, y: y), guide, font: gf) { [weak self] in
            self?.center?.close(); self?.center?.actions.openVisionGuide()
        }
        y += 22
        y = toggleRow(y, "Vision Mode", "Point to move · fist dictates · 4 for quadrants", on: visionOn && !quadrantsOn) { [weak self] in
            guard let self, let a = self.center?.actions else { return }
            if self.quadrantsOn { a.setQuadrants(false) } else { a.setVisionMode(!self.visionOn) }
            self.refreshState()
        }
        y = toggleRow(y, "Quadrant Dictation", "1 to 4 fingers dictate · fist rests", on: quadrantsOn) { [weak self] in
            guard let self, let a = self.center?.actions else { return }
            if self.quadrantsOn { a.setVisionMode(false) } else { a.setQuadrants(true) }
            self.refreshState()
        }
        y = toggleRow(y, "Hand Mirror", "Rest the pointer behind the notch", on: mirrorOn) { [weak self] in
            guard let self, let a = self.center?.actions else { return }
            a.setMirror(!self.mirrorOn); self.refreshState()
        }
        y += 8

        // Shortcuts
        let bw = (w - pad * 2 - 16) / 3
        let shortcuts: [(String, () -> Void)] = [
            ("Dashboard", { [weak self] in self?.center?.close(); self?.center?.actions.openDashboard() }),
            ("Tasks", { [weak self] in self?.center?.close(); self?.center?.actions.openTasks() }),
            ("History", { [weak self] in self?.center?.close(); self?.center?.actions.openHistory() }),
        ]
        for (i, s) in shortcuts.enumerated() {
            button(NSRect(x: pad + CGFloat(i) * (bw + 8), y: y, width: bw, height: 32), s.0, gold: false, action: s.1)
        }
    }

    /// Undo (or a hint) on the left, Quit on the right, pinned to the bottom on both pages.
    private func drawFooter() {
        let w = bounds.width
        var y = bounds.height - 28
        Theme.surface2.setFill()
        NSRect(x: pad, y: y, width: w - pad * 2, height: 1).fill()
        y += 10
        let foot = Theme.sans(11.5, "Medium")
        if let u = undoTitle {
            link(NSPoint(x: pad, y: y), "Undo \(u.count > 26 ? String(u.prefix(26)) + "…" : u)", font: foot) { [weak self] in
                self?.center?.actions.undo(); self?.refreshState()
            }
        } else {
            Theme.draw("Right-click the mascot for settings", at: NSPoint(x: pad, y: y), font: Theme.sans(11), color: Theme.textMuted)
        }
        let q = "Quit \(GWConfig.name)"
        link(NSPoint(x: w - pad - Theme.size(q, font: foot).width, y: y), q, font: foot, color: Theme.textDim) { [weak self] in
            self?.center?.actions.quit()
        }
    }

    // MARK: Pieces

    /// Name on the left; up to two meters on the right (the weekly one always in the right column).
    private func planRow(_ r: NSRect, _ plan: PlanUsage.Plan, url: URL) {
        if hover == r { let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9); Theme.surface2.setFill(); p.fill() }
        Theme.draw(plan.name, at: NSPoint(x: r.minX + 10, y: r.minY + 6), font: Theme.sans(13, "SemiBold"), color: Theme.text)
        Theme.draw("Usage page ›", at: NSPoint(x: r.minX + 10, y: r.minY + 25), font: Theme.sans(10.5),
                   color: hover == r ? Theme.goldHi : Theme.textMuted)
        buttons.append((r, { NSWorkspace.shared.open(url) }))
        if let e = plan.error {
            let f = Theme.sans(11)
            let t = e.count > 30 ? String(e.prefix(30)) + "…" : e
            Theme.draw(t, at: NSPoint(x: r.maxX - 10 - Theme.size(t, font: f).width, y: r.minY + 15), font: f, color: Theme.red)
            return
        }
        let mw: CGFloat = 92
        for (i, win) in plan.windows.suffix(2).reversed().enumerated() {
            let x = r.maxX - 10 - mw - CGFloat(i) * (mw + 12)
            let hot = win.percent >= 80
            let pct = "\(Int(win.percent.rounded()))%"
            Theme.draw(win.label, at: NSPoint(x: x, y: r.minY + 6), font: Theme.sans(9.5, "Medium"), color: Theme.textMuted, kern: 1.6)
            let pf = Theme.mono(11)
            Theme.draw(pct, at: NSPoint(x: x + mw - Theme.size(pct, font: pf).width, y: r.minY + 4), font: pf, color: hot ? Theme.red : Theme.text)
            let bar = NSRect(x: x, y: r.minY + 21, width: mw, height: 4)
            Theme.surface2.setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            var fill = bar; fill.size.width = bar.width * CGFloat(min(100, max(0, win.percent)) / 100)
            (hot ? Theme.red : Theme.goldHi).setFill(); NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            let reset = PlanUsage.resetText(win.resets)
            if !reset.isEmpty {
                Theme.draw("resets \(reset)", at: NSPoint(x: x, y: r.minY + 29), font: Theme.sans(9.5), color: Theme.textMuted)
            }
        }
    }

    func drawCard(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        Theme.surface.setFill(); p.fill()
        Theme.border.setStroke(); p.lineWidth = 1; p.stroke()
    }

    private func drawGauge(_ r: NSRect, title: String, value: String, sub: String, series: [Double], warn: Bool = false,
                           selected: Bool = false, action: @escaping () -> Void) {
        drawCard(r)
        if selected || hover == r {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            (selected ? Theme.gold : Theme.borderLight).setStroke(); p.lineWidth = 1; p.stroke()
        }
        buttons.append((r, action))
        // A small chevron says the card opens: down when closed, up when open.
        let cx = r.maxX - 16, cy = r.minY + 16
        let chev = NSBezierPath()
        chev.move(to: NSPoint(x: cx - 4, y: cy + (selected ? 2 : -2)))
        chev.line(to: NSPoint(x: cx, y: cy + (selected ? -2 : 2)))
        chev.line(to: NSPoint(x: cx + 4, y: cy + (selected ? 2 : -2)))
        (selected || hover == r ? Theme.goldHi : Theme.textMuted).setStroke(); chev.lineWidth = 1.4; chev.lineCapStyle = .round; chev.stroke()
        Theme.draw(title, at: NSPoint(x: r.minX + 12, y: r.minY + 10), font: Theme.sans(9.5, "Medium"), color: Theme.textMuted, kern: 1.6)
        Theme.draw(value, at: NSPoint(x: r.minX + 12, y: r.minY + 22), font: Theme.display(26), color: warn ? Theme.red : Theme.text)
        Theme.draw(sub, at: NSPoint(x: r.minX + 12, y: r.maxY - 18), font: Theme.sans(9.5), color: Theme.textMuted)
        // Sparkline of the last minute, gold, filled underneath.
        let chart = NSRect(x: r.minX + 10, y: r.minY + 52, width: r.width - 20, height: 20)
        guard series.count > 1 else { return }
        let step = chart.width / 59
        let x0 = chart.maxX - CGFloat(series.count - 1) * step
        let line = NSBezierPath()
        for (i, v) in series.enumerated() {
            let p = NSPoint(x: x0 + CGFloat(i) * step, y: chart.maxY - CGFloat(min(1, max(0, v))) * chart.height)
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: chart.maxX, y: chart.maxY))
        fill.line(to: NSPoint(x: x0, y: chart.maxY))
        fill.close()
        (warn ? Theme.red : Theme.gold).withAlphaComponent(0.12).setFill(); fill.fill()
        (warn ? Theme.red : Theme.goldHi).setStroke(); line.lineWidth = 1.4; line.lineJoinStyle = .round; line.stroke()
    }

    /// The dropdown under the gauges: a live breakdown plus the five busiest processes.
    private func drawDetail(_ r: NSRect, _ d: Detail) {
        drawCard(r)
        let gb = { (b: Double) in String(format: "%.1f GB", b / 1_073_741_824) }
        let s = last
        let cols: [(String, String)]
        let note: String
        switch d {
        case .cpu:
            let pct = { (v: Double?) in v.map { "\(Int(($0 * 100).rounded()))%" } ?? "…" }
            cols = [("USER", pct(s?.user)), ("SYSTEM", pct(s?.system)), ("IDLE", pct(s.map { 1 - $0.cpu }))]
            let up = Int(ProcessInfo.processInfo.systemUptime)
            let load = (s?.load ?? []).map { String(format: "%.2f", $0) }.joined(separator: " · ")
            note = "Load \(load.isEmpty ? "…" : load)  ·  up \(up / 86_400)d \(up % 86_400 / 3600)h"
        case .memory:
            cols = [("APP", s.map { gb($0.app) } ?? "…"), ("WIRED", s.map { gb($0.wired) } ?? "…"), ("COMPRESSED", s.map { gb($0.compressed) } ?? "…")]
            note = "Cached files \(s.map { gb($0.cached) } ?? "…")  ·  swap \(s.map { gb($0.swapUsed) } ?? "…")"
        }
        let cw = (r.width - 28) / 3
        for (i, c) in cols.enumerated() {
            let x = r.minX + 14 + CGFloat(i) * cw
            Theme.draw(c.0, at: NSPoint(x: x, y: r.minY + 12), font: Theme.sans(9.5, "Medium"), color: Theme.textMuted, kern: 1.6)
            Theme.draw(c.1, at: NSPoint(x: x, y: r.minY + 24), font: Theme.display(20), color: i == 0 ? Theme.goldHi : Theme.text)
        }
        Theme.draw(note, at: NSPoint(x: r.minX + 14, y: r.minY + 54), font: Theme.sans(11), color: Theme.textMuted)
        Theme.surface2.setFill()
        NSRect(x: r.minX + 14, y: r.minY + 76, width: r.width - 28, height: 1).fill()

        Theme.draw(d == .cpu ? "TOP BY CPU" : "TOP BY MEMORY", at: NSPoint(x: r.minX + 14, y: r.minY + 86),
                   font: Theme.sans(9.5, "Medium"), color: Theme.textMuted, kern: 1.6)
        let am = "Activity Monitor ›", af = Theme.sans(10.5, "Medium")
        link(NSPoint(x: r.maxX - 14 - Theme.size(am, font: af).width, y: r.minY + 85), am, font: af) { [weak self] in
            self?.center?.close()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
        let top = TopProcesses.top(procs, by: d)
        if top.isEmpty {
            Theme.draw("Reading…", at: NSPoint(x: r.minX + 14, y: r.minY + 104), font: Theme.sans(12), color: Theme.textMuted)
        }
        let nf = Theme.sans(12), vf = Theme.mono(11)
        for (i, p) in top.enumerated() {
            let ry = r.minY + 104 + CGFloat(i) * 17
            let name = p.name.count > 30 ? String(p.name.prefix(30)) + "…" : p.name
            Theme.draw(name, at: NSPoint(x: r.minX + 14, y: ry), font: nf, color: i == 0 ? Theme.text : Theme.textDim)
            let v = d == .cpu ? String(format: "%.1f%%", p.cpu)
                : p.mem >= 1_073_741_824 ? gb(p.mem) : String(format: "%.0f MB", p.mem / 1_048_576)
            Theme.draw(v, at: NSPoint(x: r.maxX - 14 - Theme.size(v, font: vf).width, y: ry + 1), font: vf, color: i == 0 ? Theme.goldHi : Theme.text)
        }
    }

    private func toggleRow(_ y: CGFloat, _ title: String, _ sub: String, on: Bool, action: @escaping () -> Void) -> CGFloat {
        let r = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 42)
        if hover == r { let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10); Theme.surface.setFill(); p.fill() }
        Theme.draw(title, at: NSPoint(x: r.minX + 8, y: r.minY + 5), font: Theme.sans(13, "SemiBold"), color: Theme.text)
        Theme.draw(sub, at: NSPoint(x: r.minX + 8, y: r.minY + 22), font: Theme.sans(11), color: Theme.textMuted)
        // Switch
        let sw = NSRect(x: r.maxX - 44, y: r.midY - 10, width: 36, height: 20)
        let track = NSBezierPath(roundedRect: sw, xRadius: 10, yRadius: 10)
        (on ? Theme.gold : Theme.surface2).setFill(); track.fill()
        (on ? Theme.goldHi : Theme.borderLight).setStroke(); track.lineWidth = 1; track.stroke()
        let knob = NSBezierPath(ovalIn: NSRect(x: on ? sw.maxX - 18 : sw.minX + 2, y: sw.minY + 2, width: 16, height: 16))
        (on ? Theme.bg : Theme.textDim).setFill(); knob.fill()
        buttons.append((r, action))
        return y + 44
    }

    func button(_ r: NSRect, _ title: String, gold: Bool, action: @escaping () -> Void) {
        let hot = hover == r
        let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        (gold ? (hot ? Theme.goldHi : Theme.gold) : (hot ? Theme.surface2 : Theme.surface)).setFill(); p.fill()
        (gold ? Theme.goldHi : Theme.border).setStroke(); p.lineWidth = 1; p.stroke()
        let f = Theme.sans(12, "SemiBold")
        let s = Theme.size(title, font: f)
        Theme.draw(title, at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), font: f, color: gold ? Theme.bg : Theme.text)
        buttons.append((r, action))
    }

    func link(_ p: NSPoint, _ title: String, font: NSFont, color: NSColor = Theme.gold, action: @escaping () -> Void) {
        let s = Theme.size(title, font: font)
        let r = NSRect(x: p.x - 4, y: p.y - 3, width: s.width + 8, height: s.height + 6)
        Theme.draw(title, at: p, font: font, color: hover == r ? Theme.goldHi : color)
        buttons.append((r, action))
    }

    private func drawSpinner(center c: NSPoint) {
        let a = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)) * 360
        let track = NSBezierPath(); track.appendArc(withCenter: c, radius: 11, startAngle: 0, endAngle: 360)
        Theme.border.setStroke(); track.lineWidth = 2.5; track.stroke()
        let arc = NSBezierPath(); arc.appendArc(withCenter: c, radius: 11, startAngle: a, endAngle: a + 90)
        Theme.goldHi.setStroke(); arc.lineWidth = 2.5; arc.lineCapStyle = .round; arc.stroke()
    }
}
