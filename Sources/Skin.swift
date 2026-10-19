import UIKit
import WebKit

/// The bridge between the native Instagram-style chrome and Instagram's website.
/// Its script runs in a private JavaScript "world": it can read and click the page, but
/// Instagram's own code cannot see its variables or call it, and it never changes the page.
enum Skin {

    static let world = WKContentWorld.world(name: "privategram-skin")
    static let messageName = "skin"

    enum Tab: Int, CaseIterable {
        case home, reels, messages, search, profile
    }

    /// Which native tab a website path belongs to (nil = leave selection as is).
    /// True if `path` is `section` or anything inside it ("/reels" matches "/reels/x", not "/reelsfan/").
    static func path(_ path: String, isIn section: String) -> Bool {
        let p = path.lowercased(), s = section.lowercased()
        return p == s || p.hasPrefix(s.hasSuffix("/") ? s : s + "/")
    }

    static func isReels(_ path: String) -> Bool { Skin.path(path, isIn: "/reels") || Skin.path(path, isIn: "/reel") }

    static func tab(for path: String, profilePath: String?) -> Tab? {
        if path == "/" || path.isEmpty { return .home }
        if isReels(path) { return .reels }
        if Skin.path(path, isIn: "/direct") { return .messages }
        if Skin.path(path, isIn: "/explore") { return .search }
        if let profilePath {
            let p = (path.hasSuffix("/") ? path : path + "/").lowercased()
            if p.hasPrefix(profilePath.lowercased()) { return .profile }
        }
        return nil
    }

    /// Screens where the real app hides its tab bar (full-screen stories, open chats, login).
    static func hidesTabBar(path: String) -> Bool {
        let fullScreen = ["/direct/t", "/stories", "/accounts", "/challenge", "/create", "/live"]
        return fullScreen.contains { Skin.path(path, isIn: $0) }
    }

    /// Where each tab goes when Instagram's own nav link can't be found.
    static func fallbackPath(for tab: Tab, profilePath: String?) -> String {
        switch tab {
        case .home: return "/"
        case .reels: return "/reels/"
        case .messages: return "/direct/inbox/"
        case .search: return "/explore/"
        case .profile: return profilePath ?? "/"
        }
    }

    /// Finds Instagram's own bottom navigation bar and reports back whether you're signed in,
    /// how tall that bar is (so the native bar can sit exactly over it), your profile link and
    /// your avatar. It only reads the page: it never adds, hides, restyles or clicks anything. If Instagram changes its page so the bar can't be
    /// found, the native bar simply stays away and you get plain Instagram instead of a broken app.
    /// Per-screen CSS (keys: all, home, reels, explore, inbox, direct, stories, post, other).
    static let styles: [String: String] = Restyle.css

    static var script: String {
        let data = (try? JSONSerialization.data(withJSONObject: styles)) ?? Data("{}".utf8)
        return scriptTemplate.replacingOccurrences(of: "__PG_STYLES__", with: String(decoding: data, as: UTF8.self))
    }

    private static let scriptTemplate = #"""
    (() => {
      if (window.top !== window || window.__pgSkin) return;
      window.__pgSkin = true;
      const post = (m) => { try { window.webkit.messageHandlers.skin.postMessage(m); } catch (_) {} };
      const sel = (href) => 'a[href="' + CSS.escape(href) + '"]';

      const MAIN = ['/', '/explore/', '/reels/', '/direct/inbox/'];
      const isFixed = (el) => { const p = getComputedStyle(el).position; return p === 'fixed' || p === 'sticky'; };

      // Instagram's nav = the fixed/sticky box that holds links to at least two main sections.
      const findNav = () => {
        for (const href of ['/explore/', '/reels/', '/direct/inbox/']) {
          for (const a of document.querySelectorAll(sel(href))) {
            for (let el = a.parentElement; el && el !== document.body; el = el.parentElement) {
              if (!isFixed(el)) continue;
              if (MAIN.filter(h => el.querySelector(sel(h))).length >= 2) return el;
              break;
            }
          }
        }
        return null;
      };

      let nav = null, last = '';
      const report = (m) => { const r = JSON.stringify(m); if (r !== last) { last = r; post(m); } };
      const scan = () => {
        applyStyle();
        if (!nav || !nav.isConnected) nav = findNav();
        if (!nav) { report({ type: 'nav', found: false }); return; }
        const rect = nav.getBoundingClientRect();
        const bottomBar = rect.width > 0 && rect.height > 0 && Math.abs(rect.bottom - innerHeight) < 4;
        // Is anything (a sheet, dialog, banner, toast) drawn on top of Instagram's bar?
        let covered = [...document.querySelectorAll('[role="dialog"]')].some(d => {
          const r = d.getBoundingClientRect();
          return r.width > 0 && r.height > 0 && getComputedStyle(d).visibility !== 'hidden';
        });
        // Something wide sitting over the whole bar (a sheet or banner) — all three sample points
        // must be covered, so a passing video overlay or toast while scrolling doesn't count.
        if (!covered && bottomBar) {
          covered = [0.1, 0.5, 0.9].every(fx => {
            const hit = document.elementFromPoint(rect.left + rect.width * fx, rect.top + rect.height / 2);
            return hit && !nav.contains(hit);
          });
        }
        let profile = null, avatar = null, avatarRect = null;
        // Your profile = the nav link whose path is a single username (works in every language).
        const KNOWN = ['explore', 'reels', 'direct', 'accounts', 'create', 'stories', 'notifications', 'p', 'reel'];
        for (const link of nav.querySelectorAll('a[href]')) {
          const m = /^\/([A-Za-z0-9._]{1,30})\/?$/.exec(link.getAttribute('href') || '');
          if (m && !KNOWN.includes(m[1].toLowerCase())) { profile = link.getAttribute('href'); break; }
        }
        const img = (profile && nav.querySelector(sel(profile) + ' img')) || nav.querySelector('img[alt*="profile picture" i]');
        if (img) {
          const a = img.closest('a[href]');
          if (a && !profile) profile = a.getAttribute('href');
          if (img.complete && img.naturalWidth > 0) {
            const r = img.getBoundingClientRect();
            avatar = img.currentSrc || img.src || null;
            avatarRect = { x: r.left, y: r.top, w: r.width, h: r.height };
          }
        }
        report({ type: 'nav', found: true, bottomBar, covered, navHeight: Math.round(rect.height), profile, avatar, avatarRect });
      };

      // Share: Instagram's own share screen opens as normal (send to people on Instagram). A
      // "More" button is added to it that opens the iPhone's share sheet (Messages, WhatsApp,
      // AirDrop, Copy…), like the app. Only real taps count, so the page can't trigger it.
      const POST = /\/(p|reel|reels)\/([A-Za-z0-9_-]{5,64})(\/|$)/;
      let shareTarget = null;
      const SHARE_ICON = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="M7.5 7.5 12 3l4.5 4.5"/><path d="M7 11H5.5A1.5 1.5 0 0 0 4 12.5v7A1.5 1.5 0 0 0 5.5 21h13a1.5 1.5 0 0 0 1.5-1.5v-7a1.5 1.5 0 0 0-1.5-1.5H17"/></svg>';
      const addMoreButton = (dialog) => {
        if (dialog.querySelector('[data-pg-more]')) return;
        const b = document.createElement('div');
        b.setAttribute('data-pg-more', '');
        b.setAttribute('role', 'button');
        b.innerHTML = SHARE_ICON + '<span>More</span>';
        b.style.cssText = 'position:fixed;left:50%;bottom:96px;transform:translateX(-50%);' +
          'z-index:2147483647;display:flex;align-items:center;gap:8px;padding:12px 22px;border-radius:24px;' +
          'background:#363636;color:#fff;font:600 15px -apple-system,system-ui,sans-serif;box-shadow:0 4px 16px rgba(0,0,0,.5);cursor:pointer;';
        b.addEventListener('click', (e) => {
          if (!e.isTrusted || !shareTarget) return;
          e.preventDefault(); e.stopImmediatePropagation();
          post({ type: 'share', kind: shareTarget.kind, id: shareTarget.id });
        }, true);
        dialog.appendChild(b);
      };
      document.addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const target = e.target instanceof Element ? e.target : null;
        const button = target && target.closest('[role="button"], button, a, svg');
        if (!button) return;
        const svg = button.matches('svg') ? button : button.querySelector('svg[aria-label]');
        const label = svg ? (svg.getAttribute('aria-label') || '').toLowerCase() : '';
        if (label !== 'share' && label !== 'share post') return;
        let match = null;
        const card = button.closest('article') || button.closest('[role="dialog"]');
        if (card) for (const a of card.querySelectorAll('a[href]')) {
          const m = POST.exec(a.getAttribute('href') || ''); if (m) { match = m; break; }
        }
        if (!match) match = POST.exec(location.pathname);
        if (!match) return;
        shareTarget = { kind: match[1] === 'p' ? 'p' : 'reel', id: match[2] };
        // Wait for Instagram's share screen to appear, then add the More button to it.
        const before = new Set(document.querySelectorAll('[role="dialog"]'));
        let tries = 0;
        const look = setInterval(() => {
          const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter(d => {
            const r = d.getBoundingClientRect(); return r.width > 0 && r.height > 0;
          });
          const fresh = dialogs.find(d => !before.has(d)) || dialogs[dialogs.length - 1];
          if (fresh) { addMoreButton(fresh); clearInterval(look); }
          else if (++tries > 20) clearInterval(look);
        }, 150);
      }, true);

      // Per-screen restyling so each screen looks like the iPhone app. Applied as a constructed
      // stylesheet from this private script world (no <style> tag is added to the page).
      const STYLES = __PG_STYLES__;
      const sheet = new CSSStyleSheet();
      let sheetOn = false, lastRoute = '';
      const routeOf = (p) => {
        if (p === '/') return 'home';
        if (/^\/reels?(\/|$)/.test(p)) return 'reels';
        if (/^\/explore(\/|$)/.test(p)) return 'explore';
        if (/^\/direct\/inbox\/?$/.test(p)) return 'inbox';
        if (/^\/direct(\/|$)/.test(p)) return 'direct';
        if (/^\/stories(\/|$)/.test(p)) return 'stories';
        if (/^\/p\//.test(p)) return 'post';
        return 'other';
      };
      function applyStyle() {
        const route = routeOf(location.pathname);
        if (route === lastRoute) return;
        lastRoute = route;
        try {
          sheet.replaceSync((STYLES.all || '') + '\n' + (STYLES[route] || ''));
          if (!sheetOn) { document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]; sheetOn = true; }
        } catch (_) {}
      }

      let pending = false;
      const start = () => {
        scan();
        // At most four checks a second, however busy the page is.
        new MutationObserver(() => {
          if (!pending) { pending = true; setTimeout(() => { pending = false; scan(); }, 250); }
        }).observe(document.documentElement, { childList: true, subtree: true });
        addEventListener('resize', scan);
        setInterval(scan, 1000);
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
      else start();
    })();
    """#
}

/// Instagram-style bottom bar: five icons, no labels, avatar for Profile, black on Reels.
final class SkinTabBar: UIView {

    var onSelect: ((Skin.Tab) -> Void)?
    var onCreate: (() -> Void)?
    private(set) var selected: Skin.Tab = .home
    private var buttons: [Skin.Tab: UIButton] = [:]
    private let avatarView = UIImageView()
    private let hairline = UIView()
    private var darkMode = false

    private static let symbols: [Skin.Tab: (String, String)] = [
        .home: ("house", "house.fill"),
        .reels: ("play.rectangle", "play.rectangle.fill"),
        .messages: ("paperplane", "paperplane.fill"),
        .search: ("magnifyingglass", "magnifyingglass"),
        .profile: ("person.crop.circle", "person.crop.circle.fill"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        hairline.backgroundColor = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for tab in Skin.Tab.allCases {
            let button = UIButton(type: .system)
            button.tag = tab.rawValue
            button.accessibilityLabel = ["Home", "Reels", "Messages", "Search", "Profile"][tab.rawValue]
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            if tab == .home {
                // Long-press Home = briefly show Instagram's own bar, to tap its "+" (new post).
                button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressedHome(_:))))
            }
            buttons[tab] = button
            stack.addArrangedSubview(button)
        }

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 13
        avatarView.isHidden = true
        avatarView.isUserInteractionEnabled = false
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        if let profileButton = buttons[.profile] {
            profileButton.addSubview(avatarView)
            NSLayoutConstraint.activate([
                avatarView.centerXAnchor.constraint(equalTo: profileButton.centerXAnchor),
                avatarView.centerYAnchor.constraint(equalTo: profileButton.centerYAnchor),
                avatarView.widthAnchor.constraint(equalToConstant: 26),
                avatarView.heightAnchor.constraint(equalToConstant: 26),
            ])
        }

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 49),
        ])
        refresh()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: SkinTabBar, _) in self.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: Skin.Tab) {
        selected = tab
        refresh()
    }

    /// Reels is always black in the real app.
    func setDark(_ dark: Bool) {
        guard dark != darkMode else { return }
        darkMode = dark
        refresh()
    }

    func setAvatar(_ image: UIImage?) {
        avatarView.image = image
        avatarView.isHidden = image == nil
        refresh()
    }

    private func refresh() {
        let config = UIImage.SymbolConfiguration(pointSize: 23, weight: .regular)
        for (tab, button) in buttons {
            let isOn = tab == selected
            let image: UIImage?
            if let drawn = TabIcons.icon(tab, selected: isOn) {
                image = drawn
            } else {
                let (off, on) = Self.symbols[tab]!
                image = UIImage(systemName: isOn ? on : off, withConfiguration: config)
            }
            button.setImage(tab == .profile && !avatarView.isHidden ? nil : image, for: .normal)
            button.tintColor = .label
        }
        avatarView.layer.borderWidth = selected == .profile ? 2 : 0
        avatarView.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        hairline.isHidden = darkMode
    }

    @objc private func tapped(_ sender: UIButton) {
        guard let tab = Skin.Tab(rawValue: sender.tag) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect?(tab)
    }

    @objc private func longPressedHome(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCreate?()
    }
}

/// Instagram-style tab icons, drawn here (2pt rounded strokes on a 24pt grid; filled when
/// selected), so the bar matches the real app rather than Apple's stock symbols.
enum TabIcons {
    private static var cache: [String: UIImage] = [:]

    static func icon(_ tab: Skin.Tab, selected: Bool) -> UIImage? {
        let key = "\(tab.rawValue)-\(selected)"
        if let hit = cache[key] { return hit }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        var drawn = true
        let image = renderer.image { ctx in
            let g = ctx.cgContext
            UIColor.black.setStroke(); UIColor.black.setFill()
            g.setLineWidth(2); g.setLineCap(.round); g.setLineJoin(.round)
            switch tab {
            case .home: home(g, selected)
            case .reels: reels(g, selected)
            case .messages: plane(g, selected)
            case .search: search(g, selected)
            case .profile: drawn = false
            }
        }
        guard drawn else { return nil }
        let template = image.withRenderingMode(.alwaysTemplate)
        cache[key] = template
        return template
    }

    private static func home(_ g: CGContext, _ on: Bool) {
        let house = UIBezierPath()
        house.move(to: CGPoint(x: 3, y: 21.5)); house.addLine(to: CGPoint(x: 3, y: 10.6))
        house.addLine(to: CGPoint(x: 12, y: 2.6)); house.addLine(to: CGPoint(x: 21, y: 10.6))
        house.addLine(to: CGPoint(x: 21, y: 21.5)); house.addLine(to: CGPoint(x: 15.6, y: 21.5))
        house.addLine(to: CGPoint(x: 15.6, y: 16.9))
        house.addArc(withCenter: CGPoint(x: 12, y: 16.9), radius: 3.6, startAngle: 0, endAngle: .pi, clockwise: false)
        house.addLine(to: CGPoint(x: 8.4, y: 21.5)); house.close()
        house.lineWidth = 2; house.lineJoinStyle = .round
        if on { house.fill() }
        house.stroke()
    }

    private static func reels(_ g: CGContext, _ on: Bool) {
        let box = UIBezierPath(roundedRect: CGRect(x: 2.5, y: 2.5, width: 19, height: 19), cornerRadius: 5.5)
        box.lineWidth = 2
        let play = UIBezierPath()
        play.move(to: CGPoint(x: 9.8, y: 11.2)); play.addLine(to: CGPoint(x: 9.8, y: 18))
        play.addLine(to: CGPoint(x: 15.8, y: 14.6)); play.close()
        let stripes = UIBezierPath()
        stripes.move(to: CGPoint(x: 2.5, y: 8)); stripes.addLine(to: CGPoint(x: 21.5, y: 8))
        stripes.move(to: CGPoint(x: 8.6, y: 2.7)); stripes.addLine(to: CGPoint(x: 11.3, y: 8))
        stripes.move(to: CGPoint(x: 14.4, y: 2.7)); stripes.addLine(to: CGPoint(x: 17.1, y: 8))
        stripes.lineWidth = 2; stripes.lineCapStyle = .round
        if on {
            box.fill()
            g.setBlendMode(.clear)
            play.fill(); stripes.stroke()
            g.setBlendMode(.normal)
        } else {
            box.stroke(); stripes.stroke()
            play.lineJoinStyle = .round; play.lineWidth = 1.6; play.stroke(); play.fill()
        }
    }

    private static func plane(_ g: CGContext, _ on: Bool) {
        let body = UIBezierPath()
        body.move(to: CGPoint(x: 21.6, y: 2.6)); body.addLine(to: CGPoint(x: 2.6, y: 9.4))
        body.addLine(to: CGPoint(x: 9.6, y: 13.4)); body.addLine(to: CGPoint(x: 13.6, y: 21.4)); body.close()
        body.lineWidth = 2; body.lineJoinStyle = .round
        let fold = UIBezierPath()
        fold.move(to: CGPoint(x: 21.6, y: 2.6)); fold.addLine(to: CGPoint(x: 9.6, y: 13.4))
        fold.lineWidth = 2; fold.lineCapStyle = .round
        if on {
            body.fill(); body.stroke()
            g.setBlendMode(.clear); fold.lineWidth = 1.6; fold.stroke(); g.setBlendMode(.normal)
        } else {
            body.stroke(); fold.stroke()
        }
    }

    private static func search(_ g: CGContext, _ on: Bool) {
        let w: CGFloat = on ? 3 : 2
        let ring = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 15, height: 15).insetBy(dx: (w - 2) / 2, dy: (w - 2) / 2))
        ring.lineWidth = w; ring.stroke()
        let handle = UIBezierPath()
        handle.move(to: CGPoint(x: 16.2, y: 16.2)); handle.addLine(to: CGPoint(x: 21.3, y: 21.3))
        handle.lineWidth = w; handle.lineCapStyle = .round; handle.stroke()
    }
}
