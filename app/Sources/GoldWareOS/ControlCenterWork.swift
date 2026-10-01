import AppKit

/// The control center's second page, "work": five tabs over one list, with the header's page switch
/// and the motion (page slide, tab pill, content fade) shared by both pages.
extension ControlCenterView {
    static let pageDuration: CFTimeInterval = 0.28
    static let tabDuration: CFTimeInterval = 0.22

    // MARK: Motion

    private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - min(1, max(0, t)), 3)) }

    func pageProgress(now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        guard let a = pageAnim else { return 1 }
        return Self.ease((now - a.start) / Self.pageDuration)
    }

    func tabProgress(now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        guard let a = tabAnim else { return 1 }
        return Self.ease((now - a.start) / Self.tabDuration)
    }

    /// A display-rate redraw only while something is moving.
    private func animate() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.needsDisplay = true
            if self.pageProgress() >= 1 { self.pageAnim = nil }
            if self.tabProgress() >= 1 { self.tabAnim = nil }
            if self.pageAnim == nil && self.tabAnim == nil { timer.invalidate(); self.animTimer = nil; self.needsDisplay = true }
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    func setPage(_ p: Page) {
        guard p != page else { return }
        pageAnim = (page, CACurrentMediaTime())
        page = p
        UserDefaults.standard.set(p.rawValue, forKey: "controlCenterPage")
        if detail != nil { detail = nil; procs = [] }
        center?.relayout()
        if p == .work { center?.refreshWork(force: true) }
        animate()
    }

    func setTab(_ t: WorkTab) {
        guard t != workTab else { return }
        tabAnim = (tabRect ?? .zero, CACurrentMediaTime())
        workTab = t
        expandedRepo = nil
        UserDefaults.standard.set(t.rawValue, forKey: "controlCenterWorkTab")
        animate()
    }

    func stepTab(_ d: Int) {
        let all = WorkTab.allCases
        setTab(all[(workTab.rawValue + d + all.count) % all.count])
    }

    // MARK: Header

    /// "controls · work" in the display italic next to the name; the current page is gold with a
    /// hairline under it that slides across when the page changes.
    /// The header name, shrunk so a long name still leaves room for the page switch.
    static func nameFont() -> NSFont {
        var size: CGFloat = 24
        while size > 13, Theme.size(GWConfig.name, font: Theme.display(size), kern: -0.2).width > 120 { size -= 1 }
        return Theme.display(size)
    }

    func drawPageSwitch(y: CGFloat) {
        let f = Theme.display(19, italic: true)
        let x0 = pad + 28 + Theme.size(GWConfig.name, font: Self.nameFont(), kern: -0.2).width + 14
        let a = "controls", b = "work", dot = " · "
        let wa = Theme.size(a, font: f).width, wd = Theme.size(dot, font: f).width, wb = Theme.size(b, font: f).width
        let ra = NSRect(x: x0 - 3, y: y - 3, width: wa + 6, height: 26)
        let rb = NSRect(x: x0 + wa + wd - 3, y: y - 3, width: wb + 6, height: 26)
        let onWork = page == .work
        Theme.draw(a, at: NSPoint(x: x0, y: y - 1), font: f, color: !onWork ? Theme.goldHi : hover == ra ? Theme.textDim : Theme.textMuted)
        Theme.draw(dot, at: NSPoint(x: x0 + wa, y: y - 1), font: f, color: Theme.textMuted.withAlphaComponent(0.6))
        Theme.draw(b, at: NSPoint(x: x0 + wa + wd, y: y - 1), font: f, color: onWork ? Theme.goldHi : hover == rb ? Theme.textDim : Theme.textMuted)
        // Underline glides between the two words.
        let p = pageProgress()
        let from = (pageAnim?.from ?? page) == .work ? rb : ra
        let to = onWork ? rb : ra
        let ux = from.minX + (to.minX - from.minX) * p + 3, uw = from.width + (to.width - from.width) * p - 6
        Theme.goldGradient.draw(in: NSRect(x: ux, y: y + 22, width: uw, height: 1), angle: 0)
        // A small gold dot on "work" while something needs you and you're on the other page.
        if !onWork, work.needsCount > 0 {
            Theme.goldHi.setFill()
            NSBezierPath(ovalIn: NSRect(x: rb.maxX - 1, y: y + 3, width: 5, height: 5)).fill()
        }
        buttons.append((ra, { [weak self] in self?.setPage(.controls) }))
        buttons.append((rb, { [weak self] in self?.setPage(.work) }))
    }

    // MARK: Work page

    func drawWork(top: CGFloat) {
        let w = bounds.width
        var y = top + 2
        // Tabs: a sunken track with a gold pill that slides to the chosen tab.
        let track = NSRect(x: pad, y: y, width: w - pad * 2, height: 34)
        let tp = NSBezierPath(roundedRect: track, xRadius: 11, yRadius: 11)
        Theme.surface.setFill(); tp.fill()
        Theme.border.setStroke(); tp.lineWidth = 1; tp.stroke()
        let tabs = WorkTab.allCases
        let segW = (track.width - 6) / CGFloat(tabs.count)
        let seg = { (i: Int) in NSRect(x: track.minX + 3 + CGFloat(i) * segW, y: track.minY + 3, width: segW, height: track.height - 6) }
        let target = seg(workTab.rawValue)
        var pill = target
        if let a = tabAnim, a.from != .zero {
            let p = tabProgress()
            pill = NSRect(x: a.from.minX + (target.minX - a.from.minX) * p, y: target.minY, width: target.width, height: target.height)
        }
        tabRect = target
        let pp = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
        Theme.goldSoft.setFill(); pp.fill()
        Theme.goldLine.setStroke(); pp.lineWidth = 1; pp.stroke()
        for t in tabs {
            let r = seg(t.rawValue)
            let on = t == workTab
            let lf = Theme.sans(11.5, on ? "SemiBold" : "Medium"), bf = Theme.mono(9, "Medium")
            let label = t == .needs ? "Needs" : t.label
            let badge = work.badge(t)
            let lw = Theme.size(label, font: lf).width, bw = badge.map { Theme.size($0, font: bf).width + 4 } ?? 0
            let x = r.midX - (lw + bw) / 2
            Theme.draw(label, at: NSPoint(x: x, y: r.midY - 8), font: lf, color: on ? Theme.goldHi : hover == r ? Theme.text : Theme.textDim)
            if let badge {
                let hot = t == .needs
                Theme.draw(badge, at: NSPoint(x: x + lw + 4, y: r.midY - 7), font: bf, color: hot ? Theme.gold : Theme.textMuted)
            }
            buttons.append((r, { [weak self] in self?.setTab(t) }))
        }
        y = track.maxY + 16

        // Tab content fades up into place on a switch.
        let fade = tabProgress()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setAlpha(fade)
        ctx.translateBy(x: 0, y: 6 * (1 - fade))
        defer { ctx.restoreGState() }

        let (hero, sub, subTone) = heroLine()
        Theme.draw(hero, at: NSPoint(x: pad, y: y - 4), font: Theme.display(23, italic: true), color: Theme.text)
        Theme.draw(fit(sub, Theme.sans(11), w - pad * 2), at: NSPoint(x: pad, y: y + 26), font: Theme.sans(11),
                   color: subTone == .red ? Theme.red : Theme.textMuted)
        y += 52

        if !work.loaded {
            drawShimmer(from: y)
            return
        }
        if workTab == .today, work.calendar != .ready {
            drawCalendarGate(y: y)
            return
        }
        let rows = work.rows(workTab)
        let bottom = bounds.height - 30 - 30
        var shown = 0
        for row in rows {
            let files = workTab == .repo && expandedRepo == row.title ? Array(row.files.prefix(7)) : []
            let h: CGFloat = 46 + (files.isEmpty ? 0 : CGFloat(files.count) * 16 + (row.files.count > 7 ? 16 : 0) + 6)
            if y + h > bottom || shown == 8 { break }
            drawWorkRow(NSRect(x: pad - 6, y: y, width: w - pad * 2 + 12, height: h), row, files: files)
            y += h + 2
            shown += 1
        }
        if shown < rows.count {
            let more = "+\(rows.count - shown) more" + (workTab == .needs ? " in your tasks ›" : "")
            let f = Theme.sans(11, "Medium")
            link(NSPoint(x: pad, y: y + 6), more, font: f, color: Theme.textDim) { [weak self] in
                guard let self else { return }
                if self.workTab == .needs { self.center?.close(); self.center?.actions.openTasks() }
                else if self.workTab == .repo, let root = VaultContext.resolveRoot() { NSWorkspace.shared.open(root) }
            }
        }
    }

    private enum SubTone { case muted, red }

    private func heroLine() -> (String, String, SubTone) {
        let n = work.rows(workTab).count
        switch workTab {
        case .needs:
            let sub = work.serverOffline ? "The server is offline, so only drafts are shown" : "Drafts first, then overdue, today, and approvals"
            return (n == 0 ? "Nothing needs you" : n == 1 ? "One thing needs you" : "\(n) things need you", sub, work.serverOffline ? .red : .muted)
        case .today:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "EEEE, MMMM d"
            let date = f.string(from: Date())
            guard work.calendar == .ready else { return ("Your day at a glance", date, .muted) }
            if let live = work.today.first(where: \.live) { return ("In \(live.title.count > 22 ? "a meeting" : live.title) now", date, .muted) }
            if let next = work.today.first, next.tone != .dim { return ("Next up \(next.meta.lowercased())", date, .muted) }
            return ("Clear for the rest of today", date, .muted)
        case .agents:
            let busy = work.agents.filter(\.live).count
            return (n == 0 ? "No agents running" : "\(n) agent\(n == 1 ? "" : "s") · \(busy == 0 ? "all idle" : "\(busy) working")",
                    "Your terminal chats · click one to jump to it", .muted)
        case .repo:
            let c = work.repoChanged
            return (c == 0 ? "Everything is committed" : "\(c) uncommitted file\(c == 1 ? "" : "s")", work.repoSummary, .muted)
        case .models:
            return (work.modelsSummary.isEmpty ? "Local models" : work.modelsSummary.replacingOccurrences(of: "Models hold ", with: "") + " in models",
                    "Ollama and Whisper on this Mac · unload to free memory", .muted)
        }
    }

    private func drawWorkRow(_ r: NSRect, _ row: WorkRow, files: [String]) {
        let head = NSRect(x: r.minX, y: r.minY, width: r.width, height: 46)
        let hot = hover.map { r.contains(NSPoint(x: $0.midX, y: $0.midY)) } ?? false
        if hot || !files.isEmpty {
            let p = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
            (hot ? Theme.surface2 : Theme.surface).setFill(); p.fill()
        }
        // Icon tile
        let tile = NSRect(x: head.minX + 8, y: head.midY - 14, width: 28, height: 28)
        let tp = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
        (row.tone == .gold || row.tone == .red ? Theme.goldSoft : Theme.surface).setFill(); tp.fill()
        (row.tone == .gold ? Theme.goldLine : Theme.border).setStroke(); tp.lineWidth = 1; tp.stroke()
        let tint: NSColor = row.tone == .red ? Theme.red : row.tone == .gold ? Theme.goldHi : row.tone == .dim ? Theme.textMuted : Theme.textDim
        if let img = NSImage(systemSymbolName: row.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium).applying(.init(paletteColors: [tint]))) {
            let s = img.size
            img.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // Right side: the action on hover, otherwise the meta tag.
        var right = head.maxX - 10
        if let action = row.action, let act = row.act, hot {
            let f = Theme.sans(11, "SemiBold")
            let bw = Theme.size(action, font: f).width + 20
            let br = NSRect(x: right - bw, y: head.midY - 12, width: bw, height: 24)
            let bp = NSBezierPath(roundedRect: br, xRadius: 7, yRadius: 7)
            (hover == br ? Theme.goldHi : Theme.gold).setFill(); bp.fill()
            Theme.draw(action, at: NSPoint(x: br.midX - (bw - 20) / 2, y: br.midY - 8), font: f, color: Theme.bg)
            buttons.append((br, { [weak self] in self?.perform(act) }))
            right = br.minX - 10
        } else if !row.meta.isEmpty {
            let mf = Theme.mono(9.5, "Medium")
            let mw = Theme.size(row.meta, font: mf, kern: 0.6).width
            let color: NSColor = row.tone == .red ? Theme.red : row.tone == .gold ? Theme.gold : Theme.textMuted
            Theme.draw(row.meta, at: NSPoint(x: right - mw, y: head.midY - 7), font: mf, color: color, kern: 0.6)
            right -= mw
            if row.live {
                let d = NSRect(x: right - 12, y: head.midY - 3, width: 6, height: 6)
                Theme.goldHi.withAlphaComponent(0.25).setFill(); NSBezierPath(ovalIn: d.insetBy(dx: -3, dy: -3)).fill()
                Theme.goldHi.setFill(); NSBezierPath(ovalIn: d).fill()
                right -= 14
            }
            right -= 12
        }
        if !row.files.isEmpty {
            // Chevron: this row opens a file list.
            let cx = right - 4, cy = head.midY, open = !files.isEmpty
            let ch = NSBezierPath()
            ch.move(to: NSPoint(x: cx - 3.5, y: cy + (open ? 2 : -2)))
            ch.line(to: NSPoint(x: cx, y: cy + (open ? -2 : 2)))
            ch.line(to: NSPoint(x: cx + 3.5, y: cy + (open ? 2 : -2)))
            (hot || open ? Theme.goldHi : Theme.textMuted).setStroke(); ch.lineWidth = 1.3; ch.lineCapStyle = .round; ch.stroke()
            right -= 16
        }
        let tx = tile.maxX + 11, tw = right - tx
        Theme.draw(fit(row.title, Theme.sans(12.5, "SemiBold"), tw), at: NSPoint(x: tx, y: head.minY + 7), font: Theme.sans(12.5, "SemiBold"),
                   color: row.tone == .dim ? Theme.textDim : Theme.text)
        Theme.draw(fit(row.sub, Theme.sans(10.5), tw), at: NSPoint(x: tx, y: head.minY + 25), font: Theme.sans(10.5), color: Theme.textMuted)
        // Expanded file list (Repo).
        var fy = head.maxY
        for f in files {
            let mark = String(f.prefix(1)), name = String(f.dropFirst(2))
            Theme.draw(mark, at: NSPoint(x: tx, y: fy), font: Theme.mono(10), color: mark == "+" ? Theme.green : Theme.gold)
            Theme.draw(fit(name, Theme.mono(10, "Regular"), head.maxX - 14 - tx - 14), at: NSPoint(x: tx + 14, y: fy),
                       font: Theme.mono(10, "Regular"), color: Theme.textDim)
            fy += 16
        }
        if !files.isEmpty, row.files.count > files.count {
            Theme.draw("and \(row.files.count - files.count) more", at: NSPoint(x: tx + 14, y: fy), font: Theme.sans(10.5), color: Theme.textMuted)
        }
        buttons.append((r, { [weak self] in self?.open(row) }))
    }

    private func open(_ row: WorkRow) {
        switch row.open {
        case .none: break
        case .tasks: center?.close(); center?.actions.openTasks()
        case .file(let path): center?.close(); NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .folder(let path):
            // First click lists the files here; a second click on an open row shows the folder in Finder.
            if expandedRepo == row.title { center?.close(); NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { expandedRepo = row.title; needsDisplay = true }
        case .tty(let tty): center?.close(); WorkData.focus(tty: tty)
        case .calendar:
            center?.close()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: .init())
        }
    }

    private func perform(_ act: WorkRow.Act) {
        switch act {
        case .unload(let model): WorkData.unload(model) { [weak self] in self?.center?.refreshWork(force: true) }
        case .restartWhisper:
            center?.actions.restartWhisper()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.center?.refreshWork(force: true) }
        }
    }

    private func drawCalendarGate(y: CGFloat) {
        let r = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 92)
        drawCard(r)
        let denied = work.calendar == .denied
        Theme.draw(denied ? "Calendar access is off" : "See what's next", at: NSPoint(x: r.minX + 14, y: r.minY + 14),
                   font: Theme.display(19, italic: true), color: Theme.text)
        Theme.draw(denied ? "Turn on \(GWConfig.name) in Privacy" : "Read on this Mac only",
                   at: NSPoint(x: r.minX + 14, y: r.minY + 44), font: Theme.sans(11.5), color: Theme.textMuted)
        let title = denied ? "Settings" : "Allow"
        button(NSRect(x: r.maxX - 88, y: r.minY + 30, width: 74, height: 28), title, gold: true) { [weak self] in
            if denied {
                self?.center?.close()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            } else {
                WorkData.requestCalendar { self?.center?.refreshWork(force: true) }
            }
        }
    }

    /// Placeholder rows while the first read runs (usually well under a second).
    private func drawShimmer(from y0: CGFloat) {
        var y = y0
        for i in 0..<4 {
            let r = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 40)
            Theme.surface.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 2, y: r.minY + 6, width: 28, height: 28), xRadius: 8, yRadius: 8).fill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 42, y: r.minY + 9, width: [180, 140, 200, 120][i], height: 9), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 42, y: r.minY + 24, width: [110, 90, 130, 70][i], height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            y += 48
        }
    }

    /// Shortens with an ellipsis to fit a width.
    func fit(_ s: String, _ f: NSFont, _ width: CGFloat) -> String {
        guard width > 12, Theme.size(s, font: f).width > width else { return s }
        var lo = 0, hi = s.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Theme.size(String(s.prefix(mid)) + "…", font: f).width <= width { lo = mid } else { hi = mid - 1 }
        }
        return String(s.prefix(lo)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
