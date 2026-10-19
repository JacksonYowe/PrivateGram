import WebKit
// Dev check: compiles the shipped rules, exercises the link cleaner and the page script in a real WebKit.
final class Probe: NSObject, WKNavigationDelegate {
    var done: ((WKWebView) -> Void)?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?(w) }
}
let probe = Probe()
Task { @MainActor in
    let store = WKContentRuleListStore.default()!
    do { _ = try await store.compileContentRuleList(forIdentifier: "check", encodedContentRuleList: Privacy.contentRules); print("RULES COMPILE OK") }
    catch { print("RULES FAILED:", error) }
    for s in ["https://l.instagram.com/?u=https%3A%2F%2Fl.facebook.com%2F%3Fu%3Dhttps%253A%252F%252Fexample.com%252Fa%253Fq%253Da%25252Bb%2526utm_source%253Dx%2526fbclid%253D1",
              "https://shop.example/p?q=a%2Bb&utm_medium=x&id=7&FBCLID=z"] {
        print("clean:", Privacy.cleanedExternalURL(URL(string: s)!))
    }
    print("hosts:", Privacy.host("evilfbcdn.net", isWithin: "fbcdn.net"), Privacy.host("scontent.xx.fbcdn.net", isWithin: "fbcdn.net"))
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.addUserScript(WKUserScript(source: Privacy.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 440, height: 900), configuration: cfg)
    w.navigationDelegate = probe
    probe.done = { w in
        let js = """
        JSON.stringify({
          platform: navigator.platform, mtp: navigator.maxTouchPoints,
          coarse: matchMedia('(hover: none) and (pointer: coarse)').matches,
          fine: matchMedia('(pointer: fine)').matches,
          notCoarse: matchMedia('not all and (pointer: coarse)').matches,
          width: matchMedia('(max-width: 1024px)').matches,
          mmStr: matchMedia.toString(), mmName: matchMedia.name, mmLen: matchMedia.length,
          getStr: Object.getOwnPropertyDescriptor(Navigator.prototype,'maxTouchPoints').get.toString(),
          tsStr: Function.prototype.toString.toString(), tsts: Function.prototype.toString.call(Function.prototype.toString),
          ownMatches: Object.prototype.hasOwnProperty.call(matchMedia('(pointer: coarse)'), 'matches'),
          protoThrow: (() => { try { Navigator.prototype.maxTouchPoints; return 'no throw'; } catch (e) { return e.constructor.name; } })(),
          listener: typeof matchMedia('(pointer: coarse)').addEventListener,
          normalFn: (function foo(){ return 1 }).toString()
        })
        """
        w.evaluateJavaScript(js) { r, e in print("page:", r ?? e!); exit(0) }
    }
    w.loadHTMLString("<html><head></head><body>x</body></html>", baseURL: URL(string: "https://www.instagram.com/"))
}
setvbuf(stdout, nil, _IONBF, 0); import AppKit; _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.run()
