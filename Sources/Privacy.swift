import Foundation
import WebKit

/// Everything that decides what the web view is allowed to load, send and reveal.
enum Privacy {

    // MARK: - Identity

    /// A stock Safari-on-Mac user agent (the same string iPads send in desktop mode). It names
    /// no phone model, OS build or app. Note: scripts can still see a phone-sized screen, so
    /// this hides *which* device you have rather than making you indistinguishable.
    static var userAgent: String {
        let safariMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariMajor).0 Safari/605.1.15"
    }

    /// ID of this app's own isolated website-data container (cookies, storage, cache). Nothing
    /// outside this app can read it, and it is never shared with Safari. "Erase everything"
    /// switches to a brand-new container and deletes the old one outright. The ID never leaves
    /// the phone.
    static var dataStoreID: UUID {
        UserDefaults.standard.string(forKey: storeKey).flatMap(UUID.init(uuidString:)) ?? defaultStoreID
    }
    private static let defaultStoreID = UUID(uuidString: "6C1E0F4B-2B7D-4C1E-9E4A-5F3A1D2B9C70")!
    private static let storeKey = "dataStoreID"
    private static let retiredKey = "retiredDataStoreIDs"

    /// Starts a fresh container and queues the old one for deletion. Returns the old ID.
    static func rotateDataStore() -> UUID {
        let old = dataStoreID
        UserDefaults.standard.set(UUID().uuidString, forKey: storeKey)
        let retired = (UserDefaults.standard.stringArray(forKey: retiredKey) ?? []) + [old.uuidString]
        UserDefaults.standard.set(retired, forKey: retiredKey)
        return old
    }

    /// Deletes retired containers entirely (including WebKit's internal HSTS / tracking data).
    /// One that's still in use is kept on the list and retried at the next launch.
    @MainActor private static var deleting = false

    @MainActor
    static func deleteRetiredDataStores() async {
        guard !deleting else { return } // one run at a time; anything left is retried next launch
        deleting = true
        defer { deleting = false }
        var deleted: Set<String> = []
        for id in UserDefaults.standard.stringArray(forKey: retiredKey) ?? [] {
            guard let uuid = UUID(uuidString: id), uuid != dataStoreID else { continue }
            if (try? await WKWebsiteDataStore.remove(forIdentifier: uuid)) != nil { deleted.insert(id) }
        }
        // Re-read so stores retired while this ran aren't forgotten.
        let now = UserDefaults.standard.stringArray(forKey: retiredKey) ?? []
        UserDefaults.standard.set(now.filter { !deleted.contains($0) }, forKey: retiredKey)
    }

    // MARK: - Navigation

    /// Every domain the app treats as "Meta's own" (messages, pop-ups, rules).
    static let inAppHosts = ["instagram.com", "instagr.am", "ig.me", "facebook.com", "meta.com"]

    static func isInAppHost(_ host: String?) -> Bool {
        inAppHosts.contains { Privacy.host(host, isWithin: $0) }
    }

    /// Pages that open inside the app: all of Instagram, but only the login / security /
    /// Accounts Center pages of Facebook and Meta that Instagram sign-in hops through. Any other
    /// Facebook page goes to your browser, so Facebook browsing never shares this app's cookies.
    static func isInAppPage(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        if isClickTracker(url) { return false }
        if ["instagram.com", "instagr.am", "ig.me"].contains(where: { Privacy.host(host, isWithin: $0) }) { return true }
        if ["accountscenter.facebook.com", "accountscenter.meta.com", "auth.meta.com"].contains(host ?? "") { return true }
        guard Privacy.host(host, isWithin: "facebook.com") else { return false }
        let path = url.path.lowercased()
        let loginPaths = ["/login", "/login.php", "/dialog/oauth", "/checkpoint", "/recover", "/two_step_verification",
                          "/accountscenter", "/oauth", "/privacy/consent", "/cookie/consent", "/confirmemail.php"]
        if loginPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return path.range(of: #"^/v[0-9.]+/dialog/oauth(/|$)"#, options: .regularExpression) != nil
    }

    /// Query parameters that exist only to track who clicked what.
    private static let trackingParams: Set<String> = [
        "fbclid", "igshid", "igsh", "gclid", "dclid", "msclkid", "mc_eid", "mc_cid",
        "_ga", "_gl", "yclid", "twclid", "ttclid", "si", "ref_src",
    ]

    /// Unwraps Instagram/Facebook's outbound click-trackers (l.instagram.com/?u=…, possibly nested)
    /// and strips tracking parameters, leaving every other parameter byte-for-byte intact.
    static func cleanedExternalURL(_ url: URL) -> URL {
        var url = url
        for _ in 0..<4 {
            guard isClickTracker(url),
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let target = comps.queryItems?.first(where: { $0.name == "u" })?.value,
                  let unwrapped = URL(string: target) else { break }
            url = unwrapped
        }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.percentEncodedQueryItems else { return url }
        let kept = items.filter { item in
            let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
            return !trackingParams.contains(name) && !name.hasPrefix("utm_")
        }
        comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return comps.url ?? url
    }

    /// Turns pasted text (e.g. the "log in" link from an Instagram email) into an Instagram URL
    /// the app can open itself, so the login lands in this app rather than in Safari. Unwraps
    /// Instagram/Facebook click-trackers and the link wrappers Gmail and Outlook add to emails.
    /// Returns nil unless the final link is an https Instagram (or Meta login) page.
    static func loginLink(from text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        if !raw.contains("://") { raw = "https://" + raw }
        guard var url = URL(string: raw) else { return nil }
        for _ in 0..<5 {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { break }
            let host = url.host?.lowercased() ?? ""
            func param(_ name: String) -> URL? {
                comps.queryItems?.first(where: { $0.name == name })?.value.flatMap(URL.init(string:))
            }
            var next: URL?
            if isClickTracker(url) { next = param("u") }
            else if Privacy.host(host, isWithin: "google.com") && url.path == "/url" { next = param("q") ?? param("url") }
            else if host.hasSuffix("safelinks.protection.outlook.com") { next = param("url") }
            guard let next else { break }
            url = next
        }
        guard url.scheme?.lowercased() == "https", isInAppPage(url) else { return nil }
        return url
    }

    /// Instagram/Facebook's outbound "who clicked what" redirectors.
    static func isClickTracker(_ url: URL) -> Bool {
        let h = url.host?.lowercased() ?? ""
        if ["l.instagram.com", "l.facebook.com", "lm.facebook.com"].contains(h) { return true }
        // (URL.path drops any trailing slash, so "/flx/warn/" arrives as "/flx/warn".)
        return host(h, isWithin: "facebook.com") && ["/l.php", "/flx/warn"].contains(url.path.lowercased())
    }

    /// True for `domain` itself or any subdomain of it (never lookalikes such as evilfbcdn.net).
    static func host(_ host: String?, isWithin domain: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    // MARK: - Page script

    /// Runs before any Instagram code, in the page and in its same-origin frames (cross-origin
    /// frames such as the login CAPTCHA are left untouched). It changes only what Instagram
    /// actually checks to decide "phone/tablet → push the app": the touch-point count and the
    /// pointer/hover media queries, plus `platform` so it agrees with the Mac user agent.
    /// Replaced functions report themselves as built-in browser code. This is a disguise good
    /// enough to get the desktop site, not a guarantee against a determined fingerprinting script
    /// (e.g. a rewritten media query's `.media` text shows the substitution).
    static let pageScript = #"""
    (() => {
      // Leave other sites' frames (e.g. reCAPTCHA) completely alone.
      try { void window.top.location.href; } catch (_) { return; }
      const nativeSource = new WeakMap();
      const realToString = Function.prototype.toString;
      const toString = ({ toString() {
        return nativeSource.has(this) ? nativeSource.get(this) : realToString.call(this);
      } }).toString;
      nativeSource.set(toString, realToString.call(realToString));
      Object.defineProperty(Function.prototype, 'toString',
        { ...Object.getOwnPropertyDescriptor(Function.prototype, 'toString'), value: toString });

      const replaceGetter = (proto, key, value) => {
        const original = Object.getOwnPropertyDescriptor(proto, key);
        if (!original || !original.get) return;
        const getter = Object.getOwnPropertyDescriptor({ get [key]() {
          if (!(this instanceof Navigator)) throw new TypeError('The Navigator.' + key + ' getter can only be used on instances of Navigator');
          return value;
        } }, key).get;
        nativeSource.set(getter, realToString.call(original.get));
        Object.defineProperty(proto, key, { ...original, get: getter });
      };
      replaceGetter(Navigator.prototype, 'platform', 'MacIntel');
      replaceGetter(Navigator.prototype, 'maxTouchPoints', 0);

      // Pointer/hover media features are answered as a Mac with a trackpad would answer them,
      // by swapping each one for an always-true or always-false width test before asking the
      // browser. The result is a genuine MediaQueryList, so change listeners keep working.
      const DESKTOP = { 'pointer:coarse': false, 'pointer:fine': true, 'pointer:none': false,
                        'any-pointer:coarse': false, 'any-pointer:fine': true, 'any-pointer:none': false,
                        'hover:none': false, 'hover:hover': true, 'any-hover:none': false, 'any-hover:hover': true };
      const realMatchMedia = window.matchMedia;
      const matchMedia = ({ matchMedia(query) {
        if (arguments.length === 0) return realMatchMedia.call(this); // throws exactly like Safari
        const rewritten = String(query)
          .replace(/\(\s*((?:any-)?(?:pointer|hover))\s*:\s*([a-z]+)\s*\)/gi, (whole, f, v) => {
            const key = (f + ':' + v).toLowerCase();
            return key in DESKTOP ? (DESKTOP[key] ? '(min-width: 0px)' : '(max-width: 0px)') : whole;
          })
          .replace(/\(\s*(?:any-)?(?:pointer|hover)\s*\)/gi, '(min-width: 0px)');
        return realMatchMedia.call(this, rewritten);
      } }).matchMedia;
      nativeSource.set(matchMedia, realToString.call(realMatchMedia));
      const owner = Object.prototype.hasOwnProperty.call(window, 'matchMedia') ? window : Window.prototype;
      Object.defineProperty(owner, 'matchMedia',
        { ...Object.getOwnPropertyDescriptor(owner, 'matchMedia'), value: matchMedia });

      // Stop iOS zooming the page in every time you tap a text box (Instagram's desktop CSS uses
      // small input fonts), so typing feels like the real app. Trade-off: no pinch-zoom on the
      // page, the same as Instagram's own app outside photos.
      if (window.top !== window) return;
      // The Messages inbox only lists names and last messages on a desktop-width page, so it's
      // laid out at that width (and its list enlarged to fill the phone by the restyle sheet).
      const viewportFor = () => /^\/direct\/inbox\/?$/.test(location.pathname)
        ? 'width=1264' : 'width=device-width, initial-scale=1, maximum-scale=1';
      let VIEWPORT = viewportFor();
      const fixViewport = () => {
        VIEWPORT = viewportFor();
        let meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          if (!document.head) return;
          meta = document.createElement('meta');
          meta.name = 'viewport';
          document.head.appendChild(meta);
        }
        if (meta.content !== VIEWPORT) meta.content = VIEWPORT;
      };
      const watch = () => {
        fixViewport();
        // Instagram changes pages without reloading; switch the layout width as soon as you open
        // or leave the Messages inbox.
        let lastPath = location.pathname;
        setInterval(() => { if (location.pathname !== lastPath) { lastPath = location.pathname; fixViewport(); } }, 250);
        new MutationObserver(fixViewport).observe(document.head || document.documentElement,
          { childList: true, subtree: true, attributes: true, attributeFilter: ['content'] });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watch, { once: true });
      else watch();
    })();
    """#

    // MARK: - Network blocking

    /// `^https?://(sub.)domain(:port)/` — exact host match; no lookalikes, no `user@` tricks.
    private static func hostFilter(_ domain: String, path: String = "") -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/:@]*\\.)?\(escaped)(:[0-9]+)?/" + path
    }

    /// Content-blocking rules, compiled by WebKit and enforced inside the network layer.
    /// Order matters: later rules win, and `ignore-previous-rules` un-blocks.
    static var contentRules: String {
        var rules: [[String: Any]] = []
        let metaPages = ["*instagram.com", "*instagr.am", "*ig.me", "*facebook.com", "*meta.com"]

        // 1. On any Instagram/Facebook/Meta page, block *every* network request to another
        //    company... (Only real network schemes: the page's own in-memory blob:/data: images,
        //    used for upload previews, are never touched.)
        for scheme in ["^https?://", "^wss?://"] {
            rules.append([
                "trigger": ["url-filter": scheme, "load-type": ["third-party"], "if-domain": metaPages],
                "action": ["type": "block"],
            ])
        }

        // 2. ...except their own photo/video/script servers and the CAPTCHA shown at login.
        //    Instagram pages may NOT load from facebook.com/meta.com (that's cross-site tracking);
        //    Facebook/Meta login pages may load Instagram's servers so sign-in hops still work.
        let shared = [
            hostFilter("instagram.com"), hostFilter("cdninstagram.com"), hostFilter("fbcdn.net"),
            hostFilter("fbsbx.com"),
            // CAPTCHA at sign-up/login: Meta's own image + audio challenge, and Google reCAPTCHA
            // (its script, challenge images/audio, anti-bot check and fonts). Captcha paths only.
            hostFilter("facebook.com", path: "captcha/"),
            hostFilter("google.com", path: "recaptcha/"), hostFilter("google.com", path: "js/bg/"),
            hostFilter("gstatic.com", path: "recaptcha/"), hostFilter("fonts.gstatic.com"),
            hostFilter("recaptcha.net"),
        ]
        let allowList: [(pages: [String], filters: [String])] = [
            (["*instagram.com"], shared),
            (["*facebook.com", "*meta.com"], shared + [hostFilter("facebook.com"), hostFilter("meta.com")]),
        ]
        for (pages, filters) in allowList {
            for filter in filters {
                rules.append([
                    "trigger": ["url-filter": filter, "load-type": ["third-party"], "if-domain": pages],
                    "action": ["type": "ignore-previous-rules"],
                ])
            }
        }

        // 3. Always block known ad/analytics trackers, whatever page they're on.
        let trackers = [
            hostFilter("connect.facebook.net"),
            hostFilter("facebook.com", path: "tr/"), hostFilter("facebook.com", path: "tr\\?"),
            hostFilter("doubleclick.net"), hostFilter("google-analytics.com"),
            hostFilter("googletagmanager.com"), hostFilter("googleadservices.com"),
            hostFilter("googlesyndication.com"), hostFilter("scorecardresearch.com"),
            hostFilter("branch.io"), hostFilter("app-measurement.com"),
        ]
        // 4. Block Instagram/Facebook's own behaviour-logging endpoints (what you look at,
        //    for how long, scroll/tap events, performance beacons). None of these are needed
        //    for the site to work.
        let telemetry = [
            hostFilter("instagram.com", path: "ajax/bz"),
            hostFilter("instagram.com", path: "ajax/logging/"),
            hostFilter("instagram.com", path: "logging/"),
            hostFilter("instagram.com", path: "logging_client_events"),
            hostFilter("instagram.com", path: "api/v1/web/logging/"),
            hostFilter("instagram.com", path: "ajax/qm/"),
            hostFilter("facebook.com", path: "ajax/bz"),
            hostFilter("facebook.com", path: "ajax/logging/"),
            hostFilter("facebook.com", path: "security/hsts-pixel"),
        ]
        for filter in trackers {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "block"]])
        }
        // Telemetry rules skip whole-page loads, so a profile that happens to be called
        // e.g. instagram.com/logging/ still opens.
        for filter in telemetry {
            rules.append(["trigger": ["url-filter": filter,
                                      "resource-type": ["raw", "fetch", "ping", "image", "script", "other"]],
                          "action": ["type": "block"]])
        }

        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    static let ruleListID = "privategram-shields-v1"

    /// Compiles the current rules. Returns nil on failure (never an older rule set), and callers
    /// then refuse to load anything — protection fails closed, never silently open.
    @MainActor
    static func compileRules() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        do {
            return try await store.compileContentRuleList(forIdentifier: ruleListID, encodedContentRuleList: contentRules)
        } catch {
            #if DEBUG
            print("[pg] rule compile failed:", error)
            #endif
            return nil
        }
    }

    // MARK: - Settings

    private static let shieldsKey = "shieldsEnabled"

    /// Tracker blocking. On by default; only exists as an escape hatch if Instagram changes something.
    static var shieldsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: shieldsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shieldsKey) }
    }
}
