# PrivateGram

A privacy-first way to use Instagram on iPhone and Mac — without installing Meta's app.

PrivateGram runs Instagram's own website inside a locked-down web view, blocks the tracking
around it, and (on iPhone) dresses it up with a native, app-like interface.

> **Not affiliated with, endorsed by, or connected to Instagram or Meta.** "Instagram" is a
> trademark of Meta Platforms, Inc. Using third-party clients may be against Instagram's Terms
> of Use and could get an account restricted — use at your own risk.

## What it protects

- **Tracker and telemetry blocking** — on Instagram pages every request to another company is
  blocked (except Instagram's own photo/video servers and the sign-in CAPTCHA), plus Instagram's
  own behaviour-logging endpoints. Enforced by WebKit's content blocker, and the app **fails
  closed**: if the rules can't load, nothing loads.
- **No identifiers from the app** — no advertising ID, no device ID, no analytics, no network
  requests of its own.
- **Sealed storage** — cookies and logins live in an isolated website-data store, never shared
  with Safari. A reset switches to a brand-new store and deletes the old one outright.
- **Permissions refused** — camera, microphone, location and motion sensors are always denied
  to the website.
- **Clean links** — outside links open in your default browser with Instagram/Facebook
  click-trackers unwrapped and tracking parameters (`fbclid`, `igsh`, `utm_*`…) stripped.
- **Privacy screen** — the iPhone app hides its contents in the app switcher.
- **Mac App Sandbox** — the Mac app can only reach the network and files you pick.

Instagram can still see your account, your IP address and what you do while signed in. No
client can hide that.

## Features

**iPhone**
- Native Instagram-style tab bar (Home, Reels, Messages, Search, Profile).
- Full-screen Reels, app-style Messages inbox, full-screen chats (per-screen restyling).
- Share: Instagram's own share screen, plus a **More** button for the iOS share sheet.
- Notifications: banners, sound and badges for new messages and activity — instantly while open,
  and from Background App Refresh checks. Made on the phone; no push token or server.
- Privacy panel (shake the phone, or long-press the icon → Privacy): tracker-blocking switch,
  sign in with an emailed log-in link, clear cache, erase everything.
- Always dark.

**Mac**
- Instagram's desktop layout in its own sandboxed window.
- **Privacy** menu (blocking switch, what's protected), **Reset** menu (clean slate / cache only),
  **Sign In with Email Link…** (⌘L).

## How it works

| Piece | Where |
| --- | --- |
| Blocking rules, link cleaning, data-store handling, page script | `Sources/Privacy.swift` (shared) |
| iPhone browser, navigation policy, share sheet | `Sources/BrowserViewController.swift` |
| Native tab bar + isolated-world bridge script | `Sources/Skin.swift` |
| Per-screen restyling (CSS) | `Sources/Restyle.swift` |
| Mac app | `MacSources/` |

On iPhone, Instagram decides "phone or tablet → push the app" from `navigator.maxTouchPoints`
and the pointer/hover media queries; the page script answers those like a Mac (with native-
looking functions) so the full web app loads. The tab-bar script runs in a separate
`WKContentWorld`, so Instagram's code can't see or call it.

## Build

Requirements: Xcode (iOS 17+ / macOS 14+ SDKs) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig   # then edit: team ID, bundle IDs, name
xcodegen generate
open PrivateGram.xcodeproj
```

- **PrivateGram** (iOS): pick your iPhone and Run. Use the *Release* configuration for everyday
  use. With a free Apple developer account the app must be reinstalled every 7 days.
- **PrivateGramMac**: signed locally ("Sign to Run Locally"), so it never expires.

Debug builds contain developer tools that only switch on with launch arguments (`-pgEval`,
`-pgShoot`, `-pgRecord`, `-pgLogMQ`). Their output contains account-specific data: don't attach
it to issues.

## License

[MIT](LICENSE)
