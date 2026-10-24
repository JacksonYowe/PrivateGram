import UIKit
import WebKit
import SwiftUI
import CoreImage

final class BrowserViewController: UIViewController {

    private static let home = URL(string: "https://www.instagram.com/")!

    private var webView: WKWebView!
    private var ruleList: WKContentRuleList?
    /// Nothing loads until the blocking rules exist (or you've switched blocking off yourself).
    private var rulesState: RulesState = .compiling
    private enum RulesState { case compiling, ready, failed }
    private var pendingLoad: URL?
    private var recentCrashes: [Date] = []
    private var webNavHeight: CGFloat = 0
    private var lastNavSeen = Date.distantPast
    private var revealWork: DispatchWorkItem?
    private var avatarKey: String?
    private let errorView = UILabel()
    private let tabBar = SkinTabBar()
    /// The app's back arrow in an open chat (the website has none on a phone-sized screen).
    private let chatBackButton = UIButton(type: .system)
    /// Native search on Explore (Instagram's own box doesn't work in this environment): a search
    /// bar plus a live account-suggestions list, powered by Instagram's own search endpoint.
    private let searchBar = UISearchBar()
    private let searchResults = UITableView()
    private var searchRows: [SearchRow] = []
    private var searchWork: DispatchWorkItem?
    private let avatarCache = NSCache<NSURL, UIImage>()
    private static let imageSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()
    struct SearchRow { var username = ""; var title = ""; var subtitle = ""; var avatar: URL?; var verified = false; var isQuery = false }
    private var webBottomToTabBar: NSLayoutConstraint!
    private var webBottomToSafeArea: NSLayoutConstraint!
    private var urlObservation: NSKeyValueObservation?
    private var signedInWithNativeNav = false
    /// Your profile link, learned from the page. Kept in memory only, never written to disk.
    private var profilePath: String?
    /// Long-press Home briefly shows Instagram's own bar so you tap its real "+" yourself.
    private var revealWebNav = false
    private var lastOutsideOpen = Date.distantPast
    private var dataStore: WKWebsiteDataStore { webView.configuration.websiteDataStore }

    private var darkChrome = false
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        tabBar.isHidden = true
        tabBar.onSelect = { [weak self] tab in self?.tabSelected(tab) }
        tabBar.onCreate = { [weak self] in self?.revealInstagramBar() }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -49),
        ])

        searchBar.placeholder = "Search"
        searchBar.delegate = self
        searchBar.barStyle = .black
        searchBar.isTranslucent = false
        searchBar.backgroundColor = .black
        searchBar.barTintColor = .black
        searchBar.searchTextField.returnKeyType = .search
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.isHidden = true
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 50),
        ])

        searchResults.dataSource = self
        searchResults.delegate = self
        searchResults.backgroundColor = .black
        searchResults.separatorColor = UIColor.white.withAlphaComponent(0.1)
        searchResults.rowHeight = 56
        searchResults.keyboardDismissMode = .onDrag
        searchResults.isHidden = true
        searchResults.translatesAutoresizingMaskIntoConstraints = false
        searchResults.register(UITableViewCell.self, forCellReuseIdentifier: "hit")
        view.addSubview(searchResults)
        NSLayoutConstraint.activate([
            searchResults.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            searchResults.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchResults.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchResults.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installWebView()

        let chevron = UIImage(systemName: "chevron.left",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        chatBackButton.setImage(chevron, for: .normal)
        chatBackButton.tintColor = .white
        chatBackButton.accessibilityLabel = "Back to Messages"
        chatBackButton.isHidden = true
        chatBackButton.addTarget(self, action: #selector(leaveChat), for: .touchUpInside)
        chatBackButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chatBackButton)
        NSLayoutConstraint.activate([
            chatBackButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            chatBackButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 38),
            chatBackButton.widthAnchor.constraint(equalToConstant: 44),
            chatBackButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // Swipe in from the left edge to leave a chat (also when there's no page to go back to).
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwipe(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)

        errorView.numberOfLines = 0
        errorView.textAlignment = .center
        errorView.textColor = .secondaryLabel
        errorView.font = .preferredFont(forTextStyle: .body)
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            errorView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        startShields()
        // Notification taps open the right screen.
        Alerts.shared.onOpen = { [weak self] path in
            guard let url = URL(string: path, relativeTo: Self.home)?.absoluteURL else { return }
            self?.safeLoad(url)
        }
        // Finish deleting any old data containers from a previous "erase everything".
        Task { await Privacy.deleteRetiredDataStores() }
    }

    /// Builds a fresh web view. Also used after "erase everything", so no page, history or
    /// in-memory state from the old session survives.
    private func installWebView() {
        tearDownWebView()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Privacy.dataStoreID)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isFraudulentWebsiteWarningEnabled = false // don't send URL hashes to Safe Browsing
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.userContentController.addUserScript(
            WKUserScript(source: Privacy.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: Skin.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Skin.world))
        config.userContentController.add(WeakMessageHandler(self), contentWorld: Skin.world, name: Skin.messageName)
        #if DEBUG
        // Dev-only (launch with -pgLogMQ): remember which media queries the page asks.
        if ProcessInfo.processInfo.arguments.contains("-pgLogMQ") {
        config.userContentController.addUserScript(WKUserScript(source: """
        (() => { const q = window.__pgMQ = new Set(); const mm = window.matchMedia;
          window.matchMedia = function (s) { q.add(String(s)); return mm.apply(this, arguments); }; })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView
        webView.customUserAgent = Privacy.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false // previews would silently load pages
        webView.isInspectable = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, belowSubview: tabBar)

        // When the native bar is up, the web view runs underneath it by exactly the height of
        // Instagram's own bottom bar, so that bar sits hidden behind ours. The page itself is
        // never modified.
        webBottomToTabBar = webView.bottomAnchor.constraint(equalTo: tabBar.topAnchor)
        webBottomToSafeArea = webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webBottomToSafeArea,
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        tabBar.isHidden = true
        signedInWithNativeNav = false

        // Instagram is a single-page app; this fires on every in-page navigation too.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.revealWebNav = false
                // Only Instagram's own pages get the native bar (the bar reports come from them).
                if !Privacy.host(self.webView.url?.host, isWithin: "instagram.com") { self.signedInWithNativeNav = false }
                self.updateChrome()
            }
        }
        applyShields()
    }

    private func showError(_ text: String) {
        errorView.text = text
        errorView.isHidden = false
    }

    /// Stops and removes the current web view so nothing it runs can touch storage any more.
    private func tearDownWebView() {
        guard let old = webView else { return }
        urlObservation = nil
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.stopLoading()
        old.configuration.userContentController.removeAllUserScripts()
        old.configuration.userContentController.removeAllScriptMessageHandlers()
        old.removeFromSuperview()
    }

    // MARK: - Shields gate

    /// Compiles the blocking rules, then performs whatever load was waiting for them.
    private func startShields() {
        rulesState = .compiling
        errorView.isHidden = true
        Task { @MainActor in
            ruleList = await Privacy.compileRules()
            rulesState = ruleList == nil ? .failed : .ready
            applyShields()
            safeLoad(pendingLoad ?? Self.home)
        }
    }

    /// Every load goes through here, so nothing can reach the network before the rules apply.
    private func safeLoad(_ url: URL) {
        switch rulesState {
        case .compiling:
            pendingLoad = url
        case .failed where Privacy.shieldsEnabled:
            pendingLoad = url
            showError("Privacy protection couldn't start, so nothing was loaded.\nPull down to try again.")
        case .ready, .failed:
            pendingLoad = nil
            webView.load(URLRequest(url: url))
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only dev hook (launch with -pgEval): JavaScript dropped in /tmp/pg-eval.js runs
    /// in the page. Never compiled into device or Release builds.
    private lazy var debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        let path = "/tmp/pg-eval.js"
        guard let self, let js = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        self.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            let out: String
            switch result {
            case .success(let v): out = "\(v)"
            case .failure(let e): out = "ERROR \(e)"
            }
            try? out.write(toFile: "/tmp/pg-eval.out", atomically: true, encoding: .utf8)
        }
    }
    #endif

    #if DEBUG
    static let layoutJS = #"""
        const ICONS = new Set(['like','unlike','comment','share','share post','save','remove','more','more options','audio is muted','audio is playing','repost','reels','home','search','explore','messages','direct','new post','create','notifications','close','back','go back','previous','next','new message','emoji','voice clip','add photo or video','audio','verified','pause','play','menu','settings','options']);
        const out = []; let n = 0;
        const walk = (el, depth, path) => {
          if (n > 3000 || depth > 45) return;
          const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
          const svgLabel = el.tagName === 'svg' ? (el.getAttribute('aria-label') || '').toLowerCase() : '';
          const big = r.width * r.height > 1200 || el.tagName === 'VIDEO' || el.tagName === 'IMG' || ICONS.has(svgLabel);
          if (big && cs.display !== 'none') {
            n++;
            out.push({ p: path, d: depth, t: el.tagName, cls: (typeof el.className === 'string' ? el.className.split(' ').slice(0, 8).join(' ') : ''),
              role: el.getAttribute('role') || '', icon: ICONS.has(svgLabel) ? svgLabel : '',
              href: (el.tagName === 'A' ? (el.getAttribute('href') || '').replace(/^\/[^\/]+\/$/, '/<user>/').replace(/\/(p|reel|reels|stories|t)\/[^\/]+/, '/$1/<id>') : ''),
              x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height),
              pos: cs.position, disp: cs.display, fd: cs.flexDirection, ov: cs.overflowY, snap: cs.scrollSnapType, sa: cs.scrollSnapAlign,
              z: cs.zIndex, mw: cs.maxWidth, pad: cs.padding, mar: cs.margin, br: cs.borderRadius, bg: cs.backgroundColor, fs: cs.fontSize,
              st: el.scrollHeight > el.clientHeight + 4 ? (el.scrollHeight + '/' + el.clientHeight) : '' });
          }
          [...el.children].forEach((c, i) => walk(c, depth + 1, path + '.' + i));
        };
        walk(document.body, 0, 'b');
        const first = (sel) => { const a = document.querySelector(sel); return a ? a.getAttribute('href') : null; };
        return JSON.stringify({ path: location.pathname.replace(/\/[^\/]+\/$/, '/<x>/'), vw: innerWidth, vh: innerHeight,
          links: { post: first('main a[href^="/p/"]') || first('a[href^="/p/"]'), story: first('a[href^="/stories/"]') },
          nodes: out });
        """#

    /// Dev-only (-pgSearchProbe): type a query into Explore search, then dump what appears.
    private func searchProbe() {
        var stage = 0
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self, rulesState == .ready, signedInWithNativeNav || stage > 0 else { return }
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            switch stage {
            case 0:
                safeLoad(URL(string: "https://www.instagram.com/explore/")!)
            case 1:
                let type = #"""
                const inp = document.querySelector('input[aria-label="Search input"], input[placeholder="Search"]');
                if (!inp) return 'no input';
                const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                inp.focus(); setter.call(inp, 'cat');
                inp.dispatchEvent(new Event('input', { bubbles: true }));
                inp.dispatchEvent(new Event('change', { bubbles: true }));
                return 'typed';
                """#
                webView.evaluateJavaScript(type, in: nil, in: Skin.world) { _ in }
            default:
                let dump = #"""
                const pick = (el) => { const r = el.getBoundingClientRect();
                  return { t: el.tagName, role: el.getAttribute('role') || '', aria: (el.getAttribute('aria-label')||'').slice(0,30),
                    cls: (typeof el.className === 'string' ? el.className.split(' ').slice(0,4).join(' ') : ''),
                    x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height),
                    pos: getComputedStyle(el).position, ov: getComputedStyle(el).overflow, z: getComputedStyle(el).zIndex, vis: r.width>0&&r.height>0 }; };
                const inp = document.querySelector('input[aria-label="Search input"], input[placeholder="Search"]');
                const links = [...document.querySelectorAll('a[href^="/"]')].filter(a => { const r=a.getBoundingClientRect(); return r.width>0 && r.y>40; }).slice(0,12).map(pick);
                // walk up from the input to find the results container (a tall scrollable sibling)
                let container = null;
                if (inp) { let p = inp.parentElement; for (let i=0;i<10 && p;i++,p=p.parentElement){ const r=p.getBoundingClientRect(); if (r.height>150){ container=pick(p); break; } } }
                return JSON.stringify({ url: location.pathname, inputValue: inp ? inp.value : null, inputVis: inp ? (inp.getBoundingClientRect().width>0) : false, container, resultLinks: links });
                """#
                webView.callAsyncJavaScript(dump, arguments: [:], in: nil, in: Skin.world) { result in
                    if case .success(let v) = result, let text = v as? String {
                        try? text.write(to: docs.appendingPathComponent("search.json"), atomically: true, encoding: .utf8)
                    }
                }
                let root: UIView = self.view
                let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in root.drawHierarchy(in: root.bounds, afterScreenUpdates: true) }
                try? image.pngData()?.write(to: docs.appendingPathComponent("search.png"))
                try? "done".write(to: docs.appendingPathComponent("search-done.txt"), atomically: true, encoding: .utf8)
                timer.invalidate()
            }
            stage += 1
        }
    }

        /// Dev-only (launch with -pgInspect <path>): load a page, then dump search/button structure
    /// (inputs, roles, aria-labels, nav links) + a screenshot, for layout work. Browsing only.
    private func inspect(_ path: String) {
        var stage = 0
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] timer in
            guard let self, rulesState == .ready, signedInWithNativeNav || stage > 0 else { return }
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            if stage == 0 {
                if let url = URL(string: path, relativeTo: Self.home)?.absoluteURL { safeLoad(url) }
                stage = 1
                return
            }
            let js = #"""
            const pick = (el) => {
              const r = el.getBoundingClientRect();
              return { t: el.tagName, type: el.getAttribute('type') || '', role: el.getAttribute('role') || '',
                aria: (el.getAttribute('aria-label') || '').slice(0, 40), ph: (el.getAttribute('placeholder') || '').slice(0, 40),
                svg: (el.querySelector(':scope > svg[aria-label]')?.getAttribute('aria-label')) || '',
                href: el.tagName === 'A' ? (el.getAttribute('href') || '').replace(/^\/[^\/]+\/?$/, '/<user>/') : '',
                text: el.childElementCount === 0 ? (el.textContent || '').trim().slice(0, 30) : '',
                x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), vis: r.width > 0 && r.height > 0 };
            };
            const inputs = [...document.querySelectorAll('input, [role="textbox"], textarea, [role="search"]')].map(pick);
            const searchish = [...document.querySelectorAll('[aria-label]')].filter(e => /search|archive|share|qr/i.test(e.getAttribute('aria-label'))).map(pick);
            const navLinks = [...document.querySelectorAll('a[href], [role="button"]')].filter(e => e.querySelector('svg[aria-label]')).map(pick).filter(e => e.vis).slice(0, 30);
            const buttons = [...document.querySelectorAll('a[href], [role="button"], button')].map(pick).filter(e => e.vis && e.text && e.text.length < 24).slice(0, 40);
            const firstReel = (document.querySelector('a[href*="/reel/"]') || {}).getAttribute ? document.querySelector('a[href*="/reel/"]').getAttribute('href') : null;
            return JSON.stringify({ path: location.pathname, vw: innerWidth, firstReel, inputs, searchish, navLinks, buttons });
            """#
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: Skin.world) { result in
                if case .success(let v) = result, let text = v as? String {
                    try? text.write(to: docs.appendingPathComponent("inspect.json"), atomically: true, encoding: .utf8)
                }
            }
            let root: UIView = self.view
            let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in root.drawHierarchy(in: root.bounds, afterScreenUpdates: true) }
            try? image.pngData()?.write(to: docs.appendingPathComponent("inspect.png"))
            try? "done".write(to: docs.appendingPathComponent("inspect-done.txt"), atomically: true, encoding: .utf8)
            timer.invalidate()
        }
    }

        /// Dev-only (launch with -pgShoot <path>): once logged in, opens that page and saves a
    /// screenshot of the app to Documents/shot-1.png, shot-2.png (after a swipe-sized scroll).
    private func startShooting(_ path: String) {
        var stage = 0
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] timer in
            guard let self, rulesState == .ready, signedInWithNativeNav || stage > 0 else { return }
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            switch stage {
            case 0:
                let target = path == "PROFILE" ? (profilePath ?? "/") : path == "THREAD" ? "/direct/inbox/" : path
                if let url = URL(string: target, relativeTo: Self.home)?.absoluteURL { safeLoad(url) }
                if path == "THREAD" {
                    // Open the first chat (dev-only: tests the chat screen layout).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        self?.webView.evaluateJavaScript("(() => { const b = [...document.querySelectorAll('main div[role=navigation] div[role=button]')].find(b => { const r = b.getBoundingClientRect(); return r.height > 60 && r.height < 90 && r.width > 300; }); if (!b) return 'none'; const r = b.getBoundingClientRect(); const o = { bubbles: true, cancelable: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, pointerType: 'mouse', isPrimary: true, button: 0 }; const t = document.elementFromPoint(o.clientX, o.clientY) || b; for (const [k, C] of [['pointerdown', PointerEvent], ['mousedown', MouseEvent], ['pointerup', PointerEvent], ['mouseup', MouseEvent], ['click', MouseEvent]]) t.dispatchEvent(new C(k, o)); return 'ok'; })()",
                                                         in: nil, in: Skin.world) { _ in }
                    }
                }
            case 1, 2:
                // Count badges: only small pure-number labels and icon names, nothing else.
                let probe = #"""
                const out = [];
                for (const el of document.querySelectorAll('body *')) {
                  const t = (el.childElementCount === 0 ? el.textContent : '').trim();
                  const r = el.getBoundingClientRect();
                  const isNum = /^[0-9]{1,3}\+?$/.test(t) && r.width < 40 && r.height < 40 && r.width > 0;
                  if (!isNum) continue;
                  const chain = [];
                  for (let p = el; p && p !== document.body && chain.length < 12; p = p.parentElement) {
                    const svg = p.querySelector(':scope > svg[aria-label], :scope svg[aria-label]');
                    chain.push({ t: p.tagName, role: p.getAttribute('role') || '', href: p.tagName === 'A' ? (p.getAttribute('href') || '').replace(/^\/[^\/]+\/$/, '/<user>/') : '',
                      icon: svg ? svg.getAttribute('aria-label') : '', aria: (p.getAttribute('aria-label') || '').replace(/[^A-Za-z ]/g, '').slice(0, 40),
                      pos: getComputedStyle(p).position });
                  }
                  out.push({ text: t, x: Math.round(r.x), y: Math.round(r.y), bg: getComputedStyle(el.parentElement).backgroundColor, chain });
                }
                const labels = [...new Set([...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))
                  .filter(l => /notif|activity|unread|new|messag/i.test(l)).map(l => l.replace(/[0-9]+/g, '#')))];
                const dots = [...document.querySelectorAll('a[href], [role=button], [role=link]')].filter(a => a.querySelector('svg[aria-label="Notifications"]'))
                  .map(a => [...a.querySelectorAll('*')].filter(e => { const r = e.getBoundingClientRect(); const bg = getComputedStyle(e).backgroundColor; return r.width > 0 && r.width < 14 && /255, 48, 64|rgb\(255, 0/.test(bg); }).length);
                return JSON.stringify({ out, labels, dots });
                """#
                let badgeName = "shot-\(stage)-badges.json"
                webView.callAsyncJavaScript(probe, arguments: [:], in: nil, in: Skin.world) { result in
                    if case .success(let v) = result, let text = v as? String {
                        try? text.write(to: docs.appendingPathComponent(badgeName), atomically: true, encoding: .utf8)
                    }
                }
                let root: UIView = self.view
                let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
                    root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: docs.appendingPathComponent("shot-\(stage).png"))
                let shotName = "shot-\(stage)"
                webView.evaluateJavaScript("JSON.stringify([...(window.__pgMQ || [])])") { v, _ in
                    try? (v as? String ?? "none").write(to: docs.appendingPathComponent("\(shotName)-mq.txt"), atomically: true, encoding: .utf8)
                }
                webView.callAsyncJavaScript(Self.layoutJS, arguments: [:], in: nil, in: Skin.world) { result in
                    if case .success(let v) = result, let text = v as? String {
                        try? text.write(to: docs.appendingPathComponent("\(shotName).json"), atomically: true, encoding: .utf8)
                    }
                }
                if stage == 1 {
                    webView.evaluateJavaScript("(document.querySelector('main [style*=snap], main > div') || document.scrollingElement).scrollBy(0, innerHeight - 50)",
                                               in: nil, in: Skin.world) { _ in }
                }
            default:
                try? "done".write(to: docs.appendingPathComponent("shot-done.txt"), atomically: true, encoding: .utf8)
                timer.invalidate()
            }
            stage += 1
        }
    }

    /// Dev-only layout recorder (Debug builds, launch with -pgRecord). Steps through the main
    /// screens and saves each one's box structure — sizes, positions, layout styles, class names,
    /// icon names and partly-redacted link paths — to Documents/layout-<screen>.json. Contains
    /// account-specific data: never attach these files (or shot-*.png) to issues.
    private var recordQueue: [(name: String, path: String?)] = [
        ("home", "/"), ("reels", "/reels/"), ("explore", "/explore/"), ("inbox", "/direct/inbox/"),
        ("profile", nil), ("post", nil), ("story", nil), ("home-end", "/"),
    ]
    private var recordFound: [String: String] = [:]
    private var recordAttempts = 0
    private var stepLoads = 0
    private lazy var layoutTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { [weak self] timer in
        // Only once you're logged in (Instagram's nav bar is showing), so it never navigates
        // away while you're signing in.
        guard let self, rulesState == .ready, signedInWithNativeNav, !Skin.hidesTabBar(path: currentPath),
              presentedViewController == nil else { return }
        guard let step = recordQueue.first else { timer.invalidate(); return }
        let target = step.path ?? recordFound[step.name]
        guard let target else { recordQueue.removeFirst(); return } // e.g. no story available
        // Load the screen (at most twice — some, like stories, redirect), then record it.
        if currentPath != target, stepLoads < 2 {
            if let url = URL(string: target, relativeTo: Self.home)?.absoluteURL { safeLoad(url) }
            stepLoads += 1
            return
        }
        stepLoads = 0
        let js = Self.layoutJS
        let name = step.name
        recordQueue.removeFirst()
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: Skin.world) { [weak self] result in
            guard let self, case .success(let value) = result, let text = value as? String,
                  let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            try? text.write(to: docs.appendingPathComponent("layout-\(name).json"), atomically: true, encoding: .utf8)
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let links = obj["links"] as? [String: Any] {
                if recordFound["post"] == nil, let p = links["post"] as? String { recordFound["post"] = p }
                if recordFound["story"] == nil, let st = links["story"] as? String { recordFound["story"] = st }
            }
            if recordFound["profile"] == nil, let pp = profilePath { recordFound["profile"] = pp }
            if recordQueue.isEmpty {
                try? "done".write(to: docs.appendingPathComponent("layout-done.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-pgRecord") { _ = layoutTimer }
        if let i = args.firstIndex(of: "-pgShoot"), i + 1 < args.count { startShooting(args[i + 1]) }
        if args.contains("-pgRecordChat") {
            // Dev-only: when you open a chat, save its layout (sizes/positions/icons) and a screenshot.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                guard let self, Skin.path(currentPath, isIn: "/direct/t") else { return }
                timer.invalidate()
                guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                webView.callAsyncJavaScript(Self.layoutJS, arguments: [:], in: nil, in: Skin.world) { result in
                    if case .success(let v) = result, let text = v as? String {
                        try? text.write(to: docs.appendingPathComponent("chat.json"), atomically: true, encoding: .utf8)
                    }
                }
                let root: UIView = self.view
                let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
                    root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: docs.appendingPathComponent("chat.png"))
            }
        }
        if let i = args.firstIndex(of: "-pgInspect"), i + 1 < args.count {
            inspect(args[i + 1])
        }
        if args.contains("-pgSearchProbe") { searchProbe() }
        if args.contains("-pgSearchDemo") {
            Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                guard let self else { return }
                safeLoad(URL(string: "https://www.instagram.com/explore/")!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self else { return }
                    searchBar.isHidden = false
                    searchBar.text = "jack"
                    self.searchBar(searchBar, textDidChange: "jack")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                    guard let self, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                    let img = UIGraphicsImageRenderer(bounds: self.view.bounds).image { _ in self.view.drawHierarchy(in: self.view.bounds, afterScreenUpdates: true) }
                    try? img.pngData()?.write(to: docs.appendingPathComponent("searchdemo.png"))
                    try? "\(searchRows.count) rows".write(to: docs.appendingPathComponent("searchdemo.txt"), atomically: true, encoding: .utf8)
                }
            }
        }
        if args.contains("-pgBgCheck") {
            // Dev-only: run the background check now and record what it read (numbers only).
            Task { @MainActor in
                let ok = await BackgroundCheck.Checker().run()
                let d = UserDefaults.standard
                let text = "ok=\(ok) dms=\(d.integer(forKey: "alertsLastDMs")) activity=\(d.bool(forKey: "alertsLastActivity"))"
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? text.write(to: docs.appendingPathComponent("bgcheck.txt"), atomically: true, encoding: .utf8)
                }
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-pgEval") { _ = debugTimer }
        if ProcessInfo.processInfo.arguments.contains("-pgShowSettings") { showSettings() }
        if ProcessInfo.processInfo.arguments.contains("-pgForceTabBar") {
            webNavHeight = 50; signedInWithNativeNav = true; lastNavSeen = .distantFuture; updateChrome()
        }
        #endif
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    private func applyShields() {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if Privacy.shieldsEnabled, let ruleList {
            controller.add(ruleList)
        }
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        if rulesState == .failed && Privacy.shieldsEnabled { startShields() }
        else if webView.url == nil || webView.url?.absoluteString == "about:blank" { safeLoad(Self.home) }
        else { webView.reload() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sender.endRefreshing() }
    }

    // MARK: - Native chrome

    private var currentPath: String { webView.url?.path ?? "/" }

    private var inChat: Bool { Skin.path(currentPath, isIn: "/direct/t") }

    /// Back to the Messages list: step back if that's where you came from, otherwise open it.
    @objc private func leaveChat() {
        UISelectionFeedbackGenerator().selectionChanged()
        if let back = webView.backForwardList.backItem, Skin.path(back.url.path, isIn: "/direct/inbox") {
            webView.goBack()
        } else {
            safeLoad(URL(string: "https://www.instagram.com/direct/inbox/")!)
        }
    }

    @objc private func edgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended, inChat, gesture.translation(in: view).x > 60 else { return }
        leaveChat()
    }

    private var onSearchScreen: Bool { Skin.path(currentPath, isIn: "/explore") }

    private func updateChrome() {
        chatBackButton.isHidden = !inChat
        if inChat { view.bringSubviewToFront(chatBackButton) }
        if onSearchScreen != !searchBar.isHidden {
            searchBar.isHidden = !onSearchScreen
            if !searchBar.isHidden { view.bringSubviewToFront(searchBar) }
            else { searchBar.resignFirstResponder(); hideSearchResults() }
        }
        if onSearchScreen, !searchBar.isFirstResponder {
            // Show the current query on a results page; empty on the Explore grid.
            searchBar.text = URLComponents(url: webView.url ?? Self.home, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value?.removingPercentEncoding
        }
        let path = currentPath
        let show = signedInWithNativeNav && !revealWebNav && !Skin.hidesTabBar(path: path)
        // Pull-to-refresh only where it can't fight Instagram's own scrolling (reels, stories, chats).
        let innerScroller = Skin.isReels(path) || ["/stories", "/direct/t"].contains { Skin.path(path, isIn: $0) }
        webView.scrollView.refreshControl?.isEnabled = !innerScroller
        webBottomToTabBar.constant = webNavHeight
        if show == tabBar.isHidden {
            tabBar.isHidden = !show
            // Always switch the old constraint off before the new one on, so they never clash.
            if show { webBottomToSafeArea.isActive = false; webBottomToTabBar.isActive = true }
            else { webBottomToTabBar.isActive = false; webBottomToSafeArea.isActive = true }
        }
        let onReels = Skin.isReels(path)
        tabBar.setDark(onReels)
        if onReels != darkChrome {
            darkChrome = onReels
            view.backgroundColor = onReels ? .black : .systemBackground
            setNeedsStatusBarAppearanceUpdate()
        }
        if let tab = Skin.tab(for: path, profilePath: profilePath) { tabBar.select(tab) }
    }

    private func tabSelected(_ tab: Skin.Tab) {
        // Tapping the tab you're already on scrolls to the top; tapping again at the top refreshes,
        // like the real app.
        if tab == tabBar.selected, Skin.tab(for: currentPath, profilePath: profilePath) == tab {
            let scroll = webView.scrollView
            if scroll.contentOffset.y > 1 {
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true)
                return
            }
            if tab == .home { webView.reload(); return }
        }
        // Your profile link isn't known yet (it's learned from the page within a second).
        if tab == .profile && profilePath == nil { return }
        tabBar.select(tab)
        // A plain navigation, the same as typing the address: no scripted clicks for Instagram
        // to notice.
        let href = Skin.fallbackPath(for: tab, profilePath: profilePath)
        if let url = URL(string: href, relativeTo: Self.home)?.absoluteURL { safeLoad(url) }
    }

    /// Long-press Home: the native bar steps aside for a few seconds so you can tap Instagram's
    /// own "+" (new post) button with a real tap.
    private func revealInstagramBar() {
        revealWebNav = true
        updateChrome()
        revealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.revealWebNav = false
            self?.updateChrome()
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    fileprivate func handleSkinMessage(_ body: Any) {
        guard let msg = body as? [String: Any] else { return }
        if msg["type"] as? String == "share" { presentShareSheet(msg); return }
        if msg["type"] as? String == "shareProfile" { presentProfileShare(); return }
        if msg["type"] as? String == "badges" {
            let dms = ((msg["dms"] as? Int) ?? (msg["dms"] as? Double).map(Int.init)).map { max(0, min($0, 999)) }
            let activity = msg["activity"] as? Bool
            if let dms { tabBar.setMessagesBadge(dms) }
            if signedInWithNativeNav {
                Alerts.shared.requestPermissionIfNeeded()
                Alerts.shared.update(dms: dms, activity: activity, currentPath: currentPath)
            }
            return
        }
        guard msg["type"] as? String == "nav" else { return }
        #if DEBUG && targetEnvironment(simulator)
        print("[skin]", msg)
        #endif
        let found = msg["found"] as? Bool ?? false
        let bottomBar = msg["bottomBar"] as? Bool ?? false
        let covered = msg["covered"] as? Bool ?? false
        let height = CGFloat(msg["navHeight"] as? Double ?? 0)
        // Take over once Instagram has shown its normal bottom bar, and *stay* through scrolling:
        // Instagram slides/redraws that bar while you scroll, which must not make ours jump away
        // (that's what let Instagram's own bar show through). Step aside only for a real sheet or
        // dialog, or if the bar has been gone for over a second (a page without one).
        if found && !covered {
            lastNavSeen = Date()
            if bottomBar, height > 20, height < 100 { webNavHeight = height }
            if webNavHeight > 0 { signedInWithNativeNav = true }
        } else if covered {
            signedInWithNativeNav = false
        } else if !Skin.path(currentPath, isIn: "/direct/inbox") {
            // (The Messages inbox is laid out desktop-style with no bottom bar of Instagram's
            // own, but keeps the native one.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, Date().timeIntervalSince(lastNavSeen) > 1.1,
                      !Skin.path(currentPath, isIn: "/direct/inbox") else { return }
                signedInWithNativeNav = false
                updateChrome()
            }
        }
        if let profile = msg["profile"] as? String,
           profile.range(of: #"^/[A-Za-z0-9._]{1,30}/?$"#, options: .regularExpression) != nil {
            profilePath = profile.hasSuffix("/") ? profile : profile + "/"
        }
        // Your avatar is copied from pixels Instagram's page has already drawn, so the app never
        // makes a network request of its own.
        if !covered, let r = msg["avatarRect"] as? [String: Double], let key = msg["avatar"] as? String,
           key != avatarKey, let w = r["w"], let h = r["h"], w >= 12, h >= 12 {
            let snap = WKSnapshotConfiguration()
            snap.rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: w, height: h)
            snap.afterScreenUpdates = true
            captureAvatar(snap, key: key, retries: 2)
        }
        updateChrome()
    }

    /// The iPhone share sheet for a post or reel (the "More" button in Instagram's share screen).
    private func presentShareSheet(_ msg: [String: Any]) {
        guard presentedViewController == nil,
              let kind = msg["kind"] as? String, ["p", "reel"].contains(kind),
              let id = msg["id"] as? String, id.range(of: #"^[A-Za-z0-9_-]{5,64}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://www.instagram.com/\(kind)/\(id)/") else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    /// Copies the avatar's pixels; if it hasn't painted yet, tries again shortly.
    private func captureAvatar(_ snap: WKSnapshotConfiguration, key: String, retries: Int) {
        let source = webView
        webView.takeSnapshot(with: snap) { [weak self] image, _ in
            guard let self, source === webView, key != avatarKey else { return }
            if let image, !image.isBlank {
                avatarKey = key
                tabBar.setAvatar(image)
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.captureAvatar(snap, key: key, retries: retries - 1)
                }
            }
        }
    }

    // MARK: - Privacy panel (shake the phone, or long-press the app icon)

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { showSettings() } else { super.motionEnded(motion, with: event) }
    }

    func showSettings() {
        guard presentedViewController == nil else { return }
        let panel = SettingsView(
            shieldsEnabled: Privacy.shieldsEnabled,
            onShieldsChange: { [weak self] enabled in
                guard let self else { return }
                Privacy.shieldsEnabled = enabled
                if enabled && rulesState == .failed {
                    // Never leave an unprotected page running while protection retries.
                    webView.stopLoading()
                    webView.load(URLRequest(url: URL(string: "about:blank")!))
                    startShields()
                    return
                }
                applyShields()
                if webView.url == nil || webView.url?.absoluteString == "about:blank" { safeLoad(Self.home) }
                else { webView.reload() }
            },
            onClearCache: { [weak self] done in
                guard let self else { return }
                let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                          WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
                dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) { done() }
            },
            onWipe: { [weak self] in
                guard let self else { return }
                // Swap to a brand-new web view on a brand-new, empty data container (no cookies,
                // history or cached pages carry over), then empty the old container and delete it
                // outright, including WebKit's internal HSTS / tracking data.
                dismiss(animated: true)
                pendingLoad = nil
                Alerts.shared.clear()
                tabBar.setMessagesBadge(0)
                profilePath = nil
                avatarKey = nil
                tabBar.setAvatar(nil)
                let oldStore = dataStore
                _ = Privacy.rotateDataStore()
                installWebView()
                updateChrome()
                safeLoad(Self.home)
                let all = WKWebsiteDataStore.allWebsiteDataTypes()
                oldStore.removeData(ofTypes: all, modifiedSince: .distantPast) {
                    // Second pass catches anything the old page's last in-flight request wrote.
                    oldStore.removeData(ofTypes: all, modifiedSince: .distantPast) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            Task { await Privacy.deleteRetiredDataStores() }
                        }
                    }
                }
            },
            onHome: { [weak self] in
                guard let self else { return }
                dismiss(animated: true)
                safeLoad(Self.home)
            },
            onLoginLink: { [weak self] url in
                guard let self else { return }
                dismiss(animated: true)
                safeLoad(url)
            }
        )
        let host = UIHostingController(rootView: panel)
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    // MARK: - Links

    /// Instagram/Facebook/Meta pages open inside the app; their click-trackers never do.
    private func isInAppPage(_ url: URL) -> Bool {
        Privacy.isInAppPage(url)
    }

    private func openOutside(_ url: URL) {
        let clean = Privacy.cleanedExternalURL(url)
        // If a click-tracker couldn't be unwrapped, don't hand the tracked link to Safari.
        if Privacy.isClickTracker(clean) { return }
        // A wrapped link that points back to Instagram stays in this app.
        if isInAppPage(clean), ["http", "https"].contains(clean.scheme?.lowercased() ?? "") {
            safeLoad(clean)
            return
        }
        guard let scheme = clean.scheme?.lowercased(), ["http", "https", "mailto", "tel", "sms"].contains(scheme) else { return }
        guard Date().timeIntervalSince(lastOutsideOpen) > 1 else { return }
        lastOutsideOpen = Date()
        UIApplication.shared.open(clean)
    }
}

// MARK: - Navigation policy

extension BrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return (.cancel, preferences) }

        // Frames inside the page (e.g. a login CAPTCHA) are governed by the network shields instead.
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if !isMainFrame { return (.allow, preferences) }

        let tapped = action.navigationType == .linkActivated
        switch scheme {
        case "about":
            return (url.absoluteString == "about:blank" ? .allow : .cancel, preferences)
        case "http", "https":
            // Fail closed: no page loads (back/forward, reload, anything) without the shields,
            // unless you've switched them off yourself.
            if Privacy.shieldsEnabled && rulesState != .ready { return (.cancel, preferences) }
            if isInAppPage(url) { return (.allow, preferences) }
            // Leaving Instagram: hand off to your default browser, untracked — only for link
            // clicks (not redirects), and at most once a second so a page can't spam it.
            if tapped { openOutside(url) }
            return (.cancel, preferences)
        case "mailto", "tel", "sms":
            if tapped { openOutside(url) }
            return (.cancel, preferences)
        default:
            // data:/blob: full-page loads (could fake a login screen), instagram://,
            // itms-apps:// ("get the app" nags) and anything else: ignore.
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        #if DEBUG
        print("[pg] provisional fail:", error)
        #endif
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 /* frame load interrupted by policy */ { return }
        if !webView.canGoBack { showError("Can't reach Instagram.\nPull down to try again.") }
    }

    /// Reload after a web-content crash, but give up after 3 crashes in a minute instead of looping.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentCrashes.count <= 3 {
            if webView.url == nil { safeLoad(pendingLoad ?? Self.home) } else { webView.reload() }
        } else {
            showError("Instagram stopped responding.\nPull down to try again.")
        }
    }
}

// MARK: - Pop-ups and permissions

extension BrowserViewController: WKUIDelegate {

    /// "Open in new tab" links: keep Instagram in this view, send everything else out.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            if isInAppPage(url) { safeLoad(url) } else { openOutside(url) }
        }
        return nil
    }

    /// Camera/microphone access from the web page is always refused.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// Motion/orientation sensors are refused too (they can be used to fingerprint a device).
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// Pop-up messages are only shown from Instagram's own page (never from embedded frames),
    /// and always say where they came from.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard frame.isMainFrame, Privacy.isInAppHost(frame.securityOrigin.host) else { return }
        _ = await present(alert: message, from: frame.securityOrigin.host, confirm: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard frame.isMainFrame, Privacy.isInAppHost(frame.securityOrigin.host) else { return false }
        return await present(alert: message, from: frame.securityOrigin.host, confirm: true)
    }

    @MainActor
    private func present(alert message: String, from host: String, confirm: Bool) async -> Bool {
        guard presentedViewController == nil, view.window != nil, !isBeingDismissed, !isBeingPresented,
              UIApplication.shared.applicationState == .active else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: host, message: message, preferredStyle: .alert)
            if confirm {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
            present(alert, animated: true)
        }
    }
}

// MARK: - Messages from the skin script

extension BrowserViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              Privacy.host(message.frameInfo.securityOrigin.host, isWithin: "instagram.com") else { return }
        handleSkinMessage(message.body)
    }
}

/// WKUserContentController holds its handlers strongly; this avoids a retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private extension UIImage {
    /// True if the image is a single flat colour (e.g. captured before the avatar had painted).
    var isBlank: Bool {
        guard let cg = cgImage, cg.width > 2, cg.height > 2 else { return true }
        let w = 8, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return true }
        var lo = [UInt8](repeating: 255, count: 3), hi = [UInt8](repeating: 0, count: 3)
        for i in stride(from: 0, to: px.count, by: 4) {
            for c in 0..<3 { lo[c] = min(lo[c], px[i + c]); hi[c] = max(hi[c], px[i + c]) }
        }
        return (0..<3).allSatisfy { Int(hi[$0]) - Int(lo[$0]) < 12 }
    }
}

// MARK: - Native Explore search

extension BrowserViewController: UISearchBarDelegate {
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.text = nil
        searchBar.resignFirstResponder()
        hideSearchResults()
        if Skin.path(currentPath, isIn: "/explore/search") {
            safeLoad(URL(string: "https://www.instagram.com/explore/")!)
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        loadKeywordResults((searchBar.text ?? ""))
    }

    /// Typing: debounce, then ask Instagram for matching accounts and list them live.
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchWork?.cancel()
        guard !query.isEmpty else { hideSearchResults(); return }
        let work = DispatchWorkItem { [weak self] in self?.fetchAccounts(query) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func loadKeywordResults(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        hideSearchResults()
        guard !query.isEmpty, let enc = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://www.instagram.com/explore/search/keyword/?q=\(enc)") else {
            safeLoad(URL(string: "https://www.instagram.com/explore/")!); return
        }
        safeLoad(url)
    }

    private func hideSearchResults() {
        searchRows = []
        searchResults.isHidden = true
    }

    /// Queries Instagram's own account-search endpoint from the logged-in page (cookies + app id).
    private func fetchAccounts(_ query: String) {
        guard let enc = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        // Body of an async function; `q` arrives via the arguments dictionary below.
        let js = #"""
        try {
          const r = await fetch('/api/v1/fbsearch/account_serp/?query=' + q,
            { headers: { 'x-ig-app-id': '936619743392459' }, credentials: 'include' });
          if (!r.ok) return '[]';
          const j = await r.json();
          return JSON.stringify((j.users || []).slice(0, 12).map(x => {
            const u = x.user || x;
            return { u: u.username || '', n: u.full_name || '', v: !!u.is_verified, a: u.profile_pic_url || '' };
          }).filter(x => x.u));
        } catch (_) { return '[]'; }
        """#
        webView.callAsyncJavaScript(js, arguments: ["q": enc], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-pgSearchDemo"),
               let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let dbg: String
                switch result { case .success(let v): dbg = "OK: \(v as? String ?? String(describing: v))"; case .failure(let e): dbg = "FAIL: \(e)" }
                try? dbg.write(to: docs.appendingPathComponent("fetchdbg.txt"), atomically: true, encoding: .utf8)
            }
            #endif
            // Ignore stale responses if the query moved on.
            guard searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            var rows: [SearchRow] = [SearchRow(title: "See results for \u{201C}\(query)\u{201D}", isQuery: true)]
            if case .success(let v) = result, let text = v as? String,
               let data = text.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in arr {
                    guard let u = item["u"] as? String, !u.isEmpty else { continue }
                    let avatar = (item["a"] as? String).flatMap(URL.init(string:))
                    rows.append(SearchRow(username: u, title: u, subtitle: item["n"] as? String ?? "",
                                          avatar: avatar, verified: item["v"] as? Bool ?? false))
                }
            }
            searchRows = rows
            searchResults.isHidden = false
            view.bringSubviewToFront(searchResults)
            view.bringSubviewToFront(searchBar)
            searchResults.reloadData()
        }
    }
}

// MARK: - Search results list

extension BrowserViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { searchRows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "hit", for: indexPath)
        let row = searchRows[indexPath.row]
        cell.backgroundColor = .clear
        cell.selectionStyle = .gray
        var config = UIListContentConfiguration.subtitleCell()
        config.textProperties.color = .white
        config.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.55)
        config.imageProperties.cornerRadius = row.isQuery ? 0 : 22
        config.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        if row.isQuery {
            config.text = row.title
            config.secondaryText = nil
            config.image = UIImage(systemName: "magnifyingglass")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        } else {
            config.text = row.verified ? "\(row.username)  ✔︎" : row.username
            config.secondaryText = row.subtitle.isEmpty ? nil : row.subtitle
            config.image = placeholderAvatar()
            if let url = row.avatar { loadAvatar(url, into: tableView, at: indexPath) }
        }
        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = searchRows[indexPath.row]
        searchBar.resignFirstResponder()
        hideSearchResults()
        if row.isQuery {
            loadKeywordResults(searchBar.text ?? "")
        } else if row.username.range(of: #"^[A-Za-z0-9._]{1,40}$"#, options: .regularExpression) != nil,
                  let url = URL(string: "https://www.instagram.com/\(row.username)/") {
            searchBar.text = nil
            safeLoad(url)
        }
    }

    private func placeholderAvatar() -> UIImage? {
        let size = CGSize(width: 44, height: 44)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.18, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            UIImage(systemName: "person.fill")?.withTintColor(UIColor(white: 0.5, alpha: 1), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 12, y: 12, width: 20, height: 20))
        }
    }

    /// Avatars are fetched cookie-free from Instagram's image servers, cached in memory.
    private func loadAvatar(_ url: URL, into tableView: UITableView, at indexPath: IndexPath) {
        if let cached = avatarCache.object(forKey: url as NSURL) {
            setCellImage(cached, tableView, indexPath); return
        }
        guard let host = url.host?.lowercased(),
              Privacy.host(host, isWithin: "fbcdn.net") || Privacy.host(host, isWithin: "cdninstagram.com") else { return }
        var request = URLRequest(url: url)
        request.setValue(Privacy.userAgent, forHTTPHeaderField: "User-Agent")
        Self.imageSession.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            avatarCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                // Still the same row, and the query hasn't changed underneath it?
                guard indexPath.row < self.searchRows.count, self.searchRows[indexPath.row].avatar == url else { return }
                self.setCellImage(image, tableView, indexPath)
            }
        }.resume()
    }

    private func setCellImage(_ image: UIImage, _ tableView: UITableView, _ indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath),
              var config = cell.contentConfiguration as? UIListContentConfiguration else { return }
        config.image = image
        config.imageProperties.cornerRadius = 22
        config.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        cell.contentConfiguration = config
    }
}

// MARK: - Share profile (QR)
// MARK: - Share profile (QR)

extension BrowserViewController {
    /// Shows a QR code of your profile plus a Share button — generated on the phone, offline.
    func presentProfileShare() {
        guard presentedViewController == nil, let profilePath,
              let url = URL(string: "https://www.instagram.com\(profilePath)") else { return }
        let handle = profilePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let qr = Self.qrImage(for: url.absoluteString)
        let panel = ProfileShareView(handle: handle, qr: qr, onShare: { [weak self] in
            guard let self else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = view
            presentedViewController?.present(sheet, animated: true)
        }, onClose: { [weak self] in self?.dismiss(animated: true) })
        let host = UIHostingController(rootView: panel)
        host.overrideUserInterfaceStyle = .dark
        if let presentation = host.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    static func qrImage(for string: String) -> UIImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct ProfileShareView: View {
    let handle: String
    let qr: UIImage?
    let onShare: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("@\(handle)").font(.headline).padding(.top, 28)
            if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text("Point a camera at this code to open the profile.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(action: onShare) {
                Label("Share profile link", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

extension BrowserViewController: UIGestureRecognizerDelegate {
    /// The edge swipe only takes over in a chat when the web view has nothing to go back to
    /// (otherwise its own swipe-back already handles it).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIScreenEdgePanGestureRecognizer else { return true }
        return inChat && !webView.canGoBack
    }
}
