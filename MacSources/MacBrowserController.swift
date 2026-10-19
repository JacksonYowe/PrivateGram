import AppKit
import WebKit

/// The Mac app is a real Mac, so unlike the iPhone version it needs no disguise at all: the page
/// is never modified. It shares the iPhone app's blocking rules, link cleaning and data-store
/// handling (Privacy.swift).
final class MacBrowserController: NSViewController, NSMenuItemValidation {

    private static let home = URL(string: "https://www.instagram.com/")!

    private var webView: WKWebView!
    private var ruleList: WKContentRuleList?
    private var rulesState: RulesState = .compiling
    private enum RulesState { case compiling, ready, failed }
    private var pendingLoad: URL?
    private var lastOutsideOpen = Date.distantPast
    private var recentCrashes: [Date] = []
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var dataStore: WKWebsiteDataStore { webView.configuration.websiteDataStore }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root

        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 15)
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installWebView()
        startShields()
        Task { await Privacy.deleteRetiredDataStores() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
    }

    // MARK: - Web view

    private func installWebView() {
        if let old = webView {
            old.navigationDelegate = nil
            old.uiDelegate = nil
            old.stopLoading()
            old.removeFromSuperview()
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Privacy.dataStoreID)
        config.preferences.isFraudulentWebsiteWarningEnabled = false // don't send URL hashes to Safe Browsing
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView
        webView.customUserAgent = Privacy.userAgent // stock Safari: no app or build identifiers
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.allowsMagnification = true
        webView.isInspectable = false
        webView.underPageBackgroundColor = .black
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView, positioned: .below, relativeTo: errorLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        applyShields()
        view.window?.makeFirstResponder(webView)
    }

    private func applyShields() {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if Privacy.shieldsEnabled, let ruleList { controller.add(ruleList) }
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
    }

    // MARK: - Shields gate (nothing loads before the blocking rules are in place)

    private func startShields() {
        rulesState = .compiling
        errorLabel.isHidden = true
        Task { @MainActor in
            ruleList = await Privacy.compileRules()
            rulesState = ruleList == nil ? .failed : .ready
            applyShields()
            safeLoad(pendingLoad ?? Self.home)
        }
    }

    private func safeLoad(_ url: URL) {
        switch rulesState {
        case .compiling:
            pendingLoad = url
        case .failed where Privacy.shieldsEnabled:
            pendingLoad = url
            showError("Privacy protection couldn't start, so nothing was loaded. Press ⌘R to try again.")
        case .ready, .failed:
            pendingLoad = nil
            errorLabel.isHidden = true
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Menu actions

    @objc func goHome(_ sender: Any?) { safeLoad(Self.home) }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 2) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func zoomReset(_ sender: Any?) { webView.pageZoom = 1 }

    @objc func reloadPage(_ sender: Any?) {
        if rulesState == .failed && Privacy.shieldsEnabled { startShields() }
        else if webView.url == nil || webView.url?.absoluteString == "about:blank" { safeLoad(pendingLoad ?? Self.home) }
        else { webView.reload() }
    }

    @objc func toggleShields(_ sender: Any?) {
        Privacy.shieldsEnabled.toggle()
        if Privacy.shieldsEnabled && rulesState == .failed {
            // Never leave an unprotected page running while protection retries.
            webView.stopLoading()
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            startShields()
            return
        }
        applyShields()
        reloadPage(nil)
    }

    @objc func clearCache(_ sender: Any?) {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                  WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
        dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {}
    }

    /// Instagram's "log in without a password" email link opens in your default browser, so the
    /// login lands there instead of here. Paste the link into this box and it opens in the app.
    @objc func openLoginLink(_ sender: Any?) {
        guard let window = view.window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
        field.placeholderString = "https://www.instagram.com/…"
        // Pre-fill if what you last copied is already an Instagram link.
        // (Only looks at the clipboard if macOS says it holds a web link — never other text.)
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [.URL]) != nil || pasteboard.types?.contains(.URL) == true,
           let copied = pasteboard.string(forType: .string), Privacy.loginLink(from: copied) != nil {
            field.stringValue = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let alert = NSAlert()
        alert.messageText = "Sign in with an email link"
        alert.informativeText = "In the email from Instagram, right-click the log-in button or link, choose Copy Link, then paste it here. It opens inside this app, so you're signed in here and not in your browser."
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let url = Privacy.loginLink(from: field.stringValue) else {
                let bad = NSAlert()
                bad.messageText = "That isn't an Instagram link"
                bad.informativeText = "Copy the log-in link from the email from Instagram and try again. Only instagram.com links are opened."
                bad.beginSheetModal(for: window)
                return
            }
            safeLoad(url)
        }
    }

    /// Reset → clean slate: signs you out of every account and deletes all cookies, logins,
    /// site storage, cache, history and WebKit's internal data, and puts settings back to default.
    @objc func resetEverything(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset to a clean slate?"
        alert.informativeText = "This signs you out of every account and deletes all cookies, logins, saved site data, cache and history in this app. Settings go back to their defaults. To also end the session on Instagram's own servers, use Log out inside Instagram first."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // Swap to a brand-new web view on a brand-new, empty data container, then empty the
            // old container and delete it outright (including WebKit's internal HSTS data).
            let oldStore = dataStore
            _ = Privacy.rotateDataStore()
            pendingLoad = nil
            Privacy.shieldsEnabled = true // settings back to default
            if rulesState == .failed { startShields() }
            installWebView()
            safeLoad(Self.home)
            let all = WKWebsiteDataStore.allWebsiteDataTypes()
            oldStore.removeData(ofTypes: all, modifiedSince: .distantPast) {
                oldStore.removeData(ofTypes: all, modifiedSince: .distantPast) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        Task { await Privacy.deleteRetiredDataStores() }
                    }
                }
            }
        }
    }

    @objc func showProtections(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "What this app protects"
        alert.informativeText = """
        • Blocks every outside tracker on Instagram, plus Instagram's own activity logging (toggle in the Privacy menu).
        • Looks like plain Safari: no app name, device ID, advertising ID or analytics.
        • Camera, microphone and location are always refused to the website.
        • Outside links open in your default browser with click-tracking removed.
        • Cookies and logins are sealed in this app, separate from Safari.
        • App Sandbox: the app can only use the network and files you pick yourself.

        Instagram can still see your account, your IP address and what you do while logged in.
        """
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleShields(_:)):
            item.state = Privacy.shieldsEnabled ? .on : .off
        case #selector(goBack(_:)):
            return webView.canGoBack
        case #selector(goForward(_:)):
            return webView.canGoForward
        default: break
        }
        return true
    }

    // MARK: - Links

    private func openOutside(_ url: URL) {
        let clean = Privacy.cleanedExternalURL(url)
        if Privacy.isClickTracker(clean) { return } // never hand a still-wrapped tracker to the browser
        if Privacy.isInAppPage(clean), ["http", "https"].contains(clean.scheme?.lowercased() ?? "") {
            safeLoad(clean)
            return
        }
        guard let scheme = clean.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
        guard Date().timeIntervalSince(lastOutsideOpen) > 1 else { return }
        lastOutsideOpen = Date()
        NSWorkspace.shared.open(clean)
    }
}

// MARK: - Navigation policy

extension MacBrowserController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return (.cancel, preferences) }
        // Frames inside the page (e.g. a login CAPTCHA) are governed by the network rules.
        if !(action.targetFrame?.isMainFrame ?? true) { return (.allow, preferences) }

        let tapped = action.navigationType == .linkActivated
        switch scheme {
        case "about":
            return (url.absoluteString == "about:blank" ? .allow : .cancel, preferences)
        case "http", "https":
            if Privacy.shieldsEnabled && rulesState != .ready { return (.cancel, preferences) }
            if Privacy.isInAppPage(url) { return (.allow, preferences) }
            // Leaving Instagram: open in your default browser, untracked — only for link clicks.
            if tapped { openOutside(url) }
            return (.cancel, preferences)
        case "mailto":
            if tapped { openOutside(url) }
            return (.cancel, preferences)
        default:
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        errorLabel.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 /* interrupted by policy */ { return }
        if !webView.canGoBack { showError("Can't reach Instagram. Press ⌘R to try again.") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentCrashes.count <= 3 {
            if webView.url == nil { safeLoad(pendingLoad ?? Self.home) } else { webView.reload() }
        } else {
            showError("Instagram stopped responding. Press ⌘R to try again.")
        }
    }
}

// MARK: - Pop-ups, uploads and permissions

extension MacBrowserController: WKUIDelegate {

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            if Privacy.isInAppPage(url) { safeLoad(url) } else { openOutside(url) }
        }
        return nil
    }

    /// The photo/video picker for posting and DMs. Only files you choose are readable.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = view.window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard frame.isMainFrame, Privacy.isInAppHost(frame.securityOrigin.host), let window = view.window,
              window.attachedSheet == nil else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard frame.isMainFrame, Privacy.isInAppHost(frame.securityOrigin.host), let window = view.window,
              window.attachedSheet == nil else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}
