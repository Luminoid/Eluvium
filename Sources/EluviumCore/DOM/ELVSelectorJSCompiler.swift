import Foundation

/// Compiles a source's declarative CSS queries into one JavaScript
/// extraction program. No raw JS from a pack is ever evaluated: every
/// string is JSON-escaped into a fixed program shape, which is what keeps
/// the DOM engine clear of behavior injection and App Store
/// guideline 2.5.2 / 3.3.2 — interpreted declarative data, not downloaded
/// code.
public enum ELVSelectorJSCompiler {
    /// The one `signalPresent` definition, interpolated into the settle
    /// probe.
    private static let signalPresentJS = """
      function signalPresent(sig) {
        if (sig === "jsonld") return !!document.querySelector('script[type="application/ld+json"]');
        if (sig === "og:title") return !!document.querySelector('meta[property="og:title"]');
        if (sig === "h1") return !!document.querySelector('h1');
        try { return !!document.querySelector(sig); } catch (e) { return false; }
      }
    """

    /// The compiled program evaluates to
    /// `{ results: { key: value|null }, url, html }`. `css` supplies the
    /// queries; presence checks live in `settleProbe`. `maxHTMLBytes`
    /// bounds the `outerHTML` the program returns so a pathological page
    /// never rides tens of MB through WebKit IPC and JSON parsing first —
    /// JS slices by UTF-16 code unit, so the renderer's receipt-side byte
    /// cap stays the hard bound; this is the early one.
    public static func compile(css: [ELVCSSQuery], maxHTMLBytes: Int) -> String {
        let queryEntries = css.map { query in
            "[\(jsString(query.key)), \(jsString(query.selector)), \(jsString(query.attr ?? "text"))]"
        }.joined(separator: ",")

        return """
        (function () {
          function capped(text, cap) {
            var t = (text || "").trim();
            return cap > 0 ? t.slice(0, cap) : t;
          }
          function readAttr(el, attr) {
            if (!el) return null;
            if (attr === "text") return (el.textContent || "").trim();
            if (attr === "innerText" || attr.indexOf("innerText:") === 0) {
              return capped(el.innerText, parseInt(attr.split(":")[1] || "0", 10));
            }
            if (attr.indexOf("ancestorInnerText:") === 0) {
              var parts = attr.split(":");
              var node = el;
              for (var up = parseInt(parts[1] || "0", 10); up > 0 && node.parentElement; up--) { node = node.parentElement; }
              return capped(node.innerText, parseInt(parts[2] || "0", 10));
            }
            if (attr === "html") return el.innerHTML || null;
            if (attr === "@href") return el.getAttribute("href");
            if (attr === "@src") return el.getAttribute("src");
            if (attr === "@content") return el.getAttribute("content");
            if (attr && attr[0] === "@") return el.getAttribute(attr.slice(1));
            return el.getAttribute(attr);
          }
          var queries = [\(queryEntries)];
          var results = {};
          for (var i = 0; i < queries.length; i++) {
            var q = queries[i];
            try {
              var el = document.querySelector(q[1]);
              var v = readAttr(el, q[2]);
              results[q[0]] = (v === undefined || v === "") ? null : v;
            } catch (e) { results[q[0]] = null; }
          }
          return JSON.stringify({
            results: results,
            url: document.location ? document.location.href : null,
            html: document.documentElement ? document.documentElement.outerHTML.slice(0, \(max(maxHTMLBytes, 0))) : ""
          });
        })();
        """
    }

    /// A small settle probe: `{ length, anySignal }` — the body text length
    /// (for stability comparison) and whether any content signal is present.
    public static func settleProbe(settleSignals: [String]) -> String {
        let signalEntries = settleSignals.map(jsString).joined(separator: ",")
        return """
        (function () {
        \(signalPresentJS)
          var sigNames = [\(signalEntries)];
          var anySignal = false;
          for (var j = 0; j < sigNames.length; j++) { if (signalPresent(sigNames[j])) { anySignal = true; break; } }
          var len = (document.body && document.body.innerText ? document.body.innerText.length : 0);
          return JSON.stringify({ length: len, anySignal: anySignal });
        })();
        """
    }

    /// JSON-escapes a string into a JS string literal. `JSONEncoder` gives
    /// correct escaping for quotes, backslashes, and control chars — the
    /// guarantee that a pack string can never break out of the literal into
    /// code. Non-ASCII is emitted raw, not `\\u`-escaped, which is valid in
    /// an ES2019+ string literal (raw U+2028/U+2029 included).
    static func jsString(_ value: String) -> String {
        // Encode as a single-element array then strip the brackets, so we get
        // a quoted, fully-escaped JSON string for any input.
        guard let data = try? JSONEncoder().encode([value]),
              // swiftlint:disable:next optional_data_string_conversion
              case let json = String(decoding: data, as: UTF8.self),
              json.count >= 2 else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }
}
