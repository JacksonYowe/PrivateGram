import Foundation

/// Per-screen styling that makes Instagram's website look like the iPhone app. Selectors are
/// structural (roles, element types, layout) rather than Instagram's generated class names,
/// which change often. Keys: all, home, reels, explore, direct, stories, post, other.
enum Restyle {
    /// Reels feed: <main> > scroller > one item per reel > column > row [video | actions].
    private static let item = #"main[role="main"] > div:first-child > div"#
    private static let row = item + " > div > div"

    static let css: [String: String] = [
        // The floating "Messages" bubble from the website (the app has a Messages tab instead).
        // Explore / search: hide Instagram's own (non-working) search box and leave room at the
        // top for PrivateGram's native search bar.
        "explore": """
        [data-pg-searchbox] { display: none !important; }
        main[role="main"] { padding-top: 50px !important; }
        """,

        "all": #"div:has(> div[role="button"] svg[aria-label="Messages"]):not(:has(main, a, input, textarea, [role="dialog"])) { visibility: hidden !important; }"#,

        // An open chat: full screen like the app — no strip of profile pictures down the side and
        // no website bottom bar.
        "direct": """
        main div[role="navigation"] { display: none !important; }
        div:has(a[href="/explore/"]):has(a[href="/direct/inbox/"]):not(:has(main)) { display: none !important; }
        /* Room for the app's back button: the chat header is the outermost block holding the call
           buttons but not the message box. */
        div:has([role="textbox"], textarea) > div:has(svg[aria-label="Audio call"]):not(:has([role="textbox"], textarea)) {
          padding-left: 48px !important;
        }
        """,

        // Messages inbox. It's laid out at desktop width (the only width where Instagram lists
        // names and last messages); this lifts just the chat list out and enlarges it to fill
        // the phone, covering the desktop sidebar and the empty "Your messages" panel.
        "inbox": """
        main div[role="navigation"] {
          position: fixed !important; left: 0 !important; top: 0 !important; z-index: 10 !important;
          width: 400px !important; max-width: none !important; height: calc(100vh / 3.16) !important;
          zoom: 3.16; background: #000 !important; border: 0 !important;
        }
        div:has(> div > section > main[role="main"]) > div:not(:has(main)) { display: none !important; }
        main div[role="navigation"] > div { width: 100% !important; height: 100% !important; background: #000 !important; border: 0 !important; }
        main div[role="navigation"] > div > div:last-child { padding-bottom: 64px !important; }
        """,


        // Reels: one full-screen video per swipe with the buttons floating on top, like the app.
        "reels": """
        main[role="main"] > div:first-child { scroll-snap-type: y mandatory !important; padding: 0 !important; background: #000 !important; }
        \(item) {
          height: calc(100vh - 50px) !important; min-height: 0 !important; max-height: none !important;
          scroll-snap-align: start !important; scroll-snap-stop: always !important; padding: 0 !important;
        }
        \(item) > div { width: 100% !important; max-width: none !important; height: 100% !important; margin: 0 !important; padding: 0 !important; }
        \(row) { width: 100% !important; height: 100% !important; margin: 0 !important; padding: 0 !important; position: relative !important; }
        \(row) > div:first-child,
        \(row) > div:first-child > div,
        \(row) > div:first-child > div > div,
        \(row) > div:first-child > div > div > div {
          width: 100% !important; height: 100% !important; max-width: none !important; max-height: none !important;
          margin: 0 !important; border-radius: 0 !important; border: 0 !important;
        }
        \(row) > div:first-child video { width: 100% !important; height: 100% !important; object-fit: cover !important; }
        \(row) > div:nth-child(2) {
          position: absolute !important; right: 4px !important; bottom: 12px !important; top: auto !important;
          height: auto !important; width: 52px !important; z-index: 5 !important; justify-content: flex-end !important;
          filter: drop-shadow(0 1px 2px rgba(0,0,0,.6));
        }
        """,
    ]
}
