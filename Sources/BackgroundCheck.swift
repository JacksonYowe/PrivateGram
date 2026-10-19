import UIKit
import WebKit
import BackgroundTasks

/// Background App Refresh: every so often (iOS decides when — typically a few times a day)
/// the app quietly loads Instagram in an invisible web view with the same protections as
/// normal, reads the unread indicators, and shows a notification if something is new.
enum BackgroundCheck {
    static var taskID: String { (Bundle.main.bundleIdentifier ?? "privategram") + ".refresh" }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule() // keep the chain going
            Task { @MainActor in
                let checker = Checker()
                task.expirationHandler = { Task { @MainActor in checker.cancel() } }
                let ok = await checker.run()
                task.setTaskCompleted(success: ok)
            }
        }
    }

    /// Ask iOS for the next background check (no sooner than 15 minutes).
    static func schedule() {
        guard Alerts.shared.enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One check: load Instagram's home page (fail-closed behind the blocking rules), read the
    /// unread indicators, post notifications.
    @MainActor
    final class Checker: NSObject, WKNavigationDelegate {
        private var webView: WKWebView?
        private var finished: CheckedContinuation<Bool, Never>?

        func run() async -> Bool {
            guard Alerts.shared.enabled else { return true }
            // Protection first: no rules, no load.
            guard let rules = await Privacy.compileRules() else { return false }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Privacy.dataStoreID)
            config.preferences.isFraudulentWebsiteWarningEnabled = false
            config.mediaTypesRequiringUserActionForPlayback = .all // never play anything
            config.userContentController.addUserScript(
                WKUserScript(source: Privacy.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            if Privacy.shieldsEnabled { config.userContentController.add(rules) }
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 440, height: 900), configuration: config)
            web.customUserAgent = Privacy.userAgent
            web.navigationDelegate = self
            webView = web
            web.load(URLRequest(url: URL(string: "https://www.instagram.com/")!))

            return await withCheckedContinuation { continuation in
                finished = continuation
                // Give the page time to load and show its unread indicators, then read them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.read() }
            }
        }

        func cancel() { finish(false) }

        private func read() {
            guard let web = webView else { return }
            web.evaluateJavaScript(Skin.badgeJS, in: nil, in: .defaultClient) { [weak self] result in
                guard let self else { return }
                if case .success(let value) = result, let dict = value as? [String: Any] {
                    let dms = (dict["dms"] as? Int) ?? (dict["dms"] as? Double).map(Int.init)
                    Alerts.shared.update(dms: dms.map { max(0, min($0, 999)) }, activity: dict["activity"] as? Bool)
                    finish(dms != nil)
                } else {
                    finish(false)
                }
            }
        }

        private func finish(_ ok: Bool) {
            webView?.stopLoading()
            webView = nil
            finished?.resume(returning: ok)
            finished = nil
        }

        // Stay on Instagram only; never follow anything elsewhere.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            guard let url = action.request.url, action.targetFrame?.isMainFrame ?? true else { return (.allow, preferences) }
            let ok = url.scheme == "https" && Privacy.host(url.host, isWithin: "instagram.com")
            return (ok ? .allow : .cancel, preferences)
        }
    }
}
