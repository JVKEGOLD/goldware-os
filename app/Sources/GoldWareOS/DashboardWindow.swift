import AppKit
import WebKit

/// The GoldWare dashboard in a native window: the same page the browser shows at
/// http://127.0.0.1:4188, with the orb while the server starts.
final class DashboardWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    let window: NSWindow
    private let web: WKWebView
    private let overlay = NSView()
    private let overlayOrb = OrbView()
    private let overlayText = NSTextField(labelWithString: "Starting \(GWConfig.name)…")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private var loaded = false
    private var pendingTab: String?
    let home: URL
    var onRetry: () -> Void = {}
    /// A whitelisted goldwareos:// link was clicked in the page.
    var onShortcut: (ShortcutRoute) -> Void = { _ in }
    /// Reports "loaded <url>" or the failure, for status.json.
    var onState: (String) -> Void = { _ in }

    init(home: URL) {
        self.home = home
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        web = WKWebView(frame: .zero, configuration: config)
        super.init()

        window.title = GWConfig.name
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.bg
        window.minSize = NSSize(width: 600, height: 400)   // small enough to tile into a quarter of a laptop screen
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("GoldWareDashboard")
        if !window.setFrameUsingName("GoldWareDashboard") { window.center() }
        window.tabbingMode = .disallowed

        let toolbar = NSToolbar(identifier: "GoldWareToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { web.isInspectable = true }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg.cgColor
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        buildOverlay(in: content)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func buildOverlay(in content: NSView) {
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = Theme.bg.cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlayOrb.translatesAutoresizingMaskIntoConstraints = false
        overlayOrb.state = .connecting
        overlayOrb.tint = Theme.goldHi
        overlayText.font = Theme.sans(15, "Medium")
        overlayText.textColor = Theme.textDim
        overlayText.alignment = .center
        overlayText.translatesAutoresizingMaskIntoConstraints = false
        retry.bezelStyle = .rounded
        retry.target = self
        retry.action = #selector(tryAgain)
        retry.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay)
        overlay.addSubview(overlayOrb)
        overlay.addSubview(overlayText)
        overlay.addSubview(retry)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlayOrb.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlayOrb.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -30),
            overlayOrb.widthAnchor.constraint(equalToConstant: 96),
            overlayOrb.heightAnchor.constraint(equalToConstant: 96),
            overlayText.topAnchor.constraint(equalTo: overlayOrb.bottomAnchor, constant: 18),
            overlayText.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlayText.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -80),
            retry.topAnchor.constraint(equalTo: overlayText.bottomAnchor, constant: 14),
            retry.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        ])
    }

    // MARK: Showing

    func show(tab: String? = nil) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let tab { go(tab: tab) }
        if !loaded { overlayOrb.start() }
    }

    /// Called once the server answers, or with the reason it does not.
    func serverReady(_ problem: String?) {
        if let problem {
            overlayText.stringValue = problem
            overlayOrb.state = .shaping
            retry.isHidden = false
            return
        }
        retry.isHidden = true
        overlayText.stringValue = "Opening the dashboard…"
        var url = home
        if let tab = pendingTab, var c = URLComponents(url: home, resolvingAgainstBaseURL: false) {
            c.fragment = tab
            url = c.url ?? home
            pendingTab = nil
        }
        web.load(URLRequest(url: url))
    }

    func go(tab: String) {
        guard loaded else { pendingTab = tab; return }
        let js = "(document.querySelector('.topbar-tab[data-tab=\"\(tab)\"]') || {click(){}}).click(); window.scrollTo(0, 0);"
        web.evaluateJavaScript(js)
    }

    @objc func reload() {
        if loaded { web.reload() } else { onRetry() }
    }
    @objc func goBack() { web.goBack() }
    @objc func goForward() { web.goForward() }
    @objc func openInBrowser() { NSWorkspace.shared.open(web.url ?? home) }

    @objc private func tryAgain() {
        retry.isHidden = true
        overlayOrb.state = .connecting
        overlayText.stringValue = "Starting \(GWConfig.name)…"
        onRetry()
    }

    // MARK: Navigation

    private func isLocal(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost"].contains(url.host ?? "") || url.scheme == "about"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        // Dashboard shortcut buttons run in-app: no browser prompt. Unknown goldwareos:// links are dropped.
        if url.scheme?.lowercased() == ShortcutRoute.scheme {
            if let route = ShortcutRoute(url: url) { onShortcut(route) }
            return decisionHandler(.cancel)
        }
        // Outside links (newspaper sources, client sites) and original-file downloads go to the browser.
        if !isLocal(url) || url.path.hasPrefix("/api/original") {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        overlayOrb.stop()
        webView.evaluateJavaScript("document.title + ' | tabs: ' + document.querySelectorAll('.topbar-tab').length") { [weak self] result, _ in
            self?.onState("loaded \(webView.url?.absoluteString ?? "") | \(result as? String ?? "")")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            overlay.animator().alphaValue = 0
        } completionHandler: { self.overlay.isHidden = true }
        if let tab = pendingTab { pendingTab = nil; go(tab: tab) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded = false
        onState("failed: \(error.localizedDescription)")
        overlay.isHidden = false
        overlay.alphaValue = 1
        serverReady("The dashboard did not load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // target="_blank" and window.open: local pages open here, everything else in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isLocal(url) && !url.path.hasPrefix("/api/original") { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    // MARK: Toolbar

    private let backID = NSToolbarItem.Identifier("back"), forwardID = NSToolbarItem.Identifier("forward")
    private let reloadID = NSToolbarItem.Identifier("reload"), browserID = NSToolbarItem.Identifier("browser")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [backID, forwardID, reloadID, .flexibleSpace, browserID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let specs: [NSToolbarItem.Identifier: (String, String, Selector)] = [
            backID: ("chevron.left", "Back", #selector(goBack)),
            forwardID: ("chevron.right", "Forward", #selector(goForward)),
            reloadID: ("arrow.clockwise", "Reload", #selector(reload)),
            browserID: ("safari", "Open in Browser", #selector(openInBrowser)),
        ]
        guard let (symbol, label, action) = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}

/// GoldWare Voice's dictation history, in its own window instead of the browser.
final class HistoryWindow: NSObject {
    let window: NSWindow
    private let web = WKWebView()

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "\(GWConfig.name) Voice History"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VoiceHistory")
        if !window.setFrameUsingName("VoiceHistory") { window.center() }
        window.contentView = web
    }

    func show() {
        web.loadFileURL(Paths.historyPage, allowingReadAccessTo: Paths.dataDir)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
