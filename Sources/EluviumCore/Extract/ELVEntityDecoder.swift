/// HTML entity decoding: the full numeric forms (`&#8217;` / `&#x2019;`) plus
/// a broad named table. Production's 8-entity table left `&#8217;` in real
/// Chewy payloads undecoded — numeric support is the load-bearing part.
public enum ELVEntityDecoder {
    /// Decodes named and numeric HTML entities in `string`. Unknown entities
    /// are left verbatim rather than dropped.
    public static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = String()
        // utf8.count is O(1) on native strings and an upper bound on the
        // decoded length; `count` would grapheme-walk the input first.
        result.reserveCapacity(string.utf8.count)
        var index = string.startIndex

        while index < string.endIndex {
            let character = string[index]
            guard character == "&" else {
                result.append(character)
                index = string.index(after: index)
                continue
            }
            // The ";" search is bounded to the 32-character entity window
            // (33 with the "&" itself): an unbounded `firstIndex` scans to
            // the end of the string per "&", turning a multi-MB "&" run
            // quadratic.
            guard let semicolon = string[index...].prefix(33).firstIndex(of: ";") else {
                result.append(character)
                index = string.index(after: index)
                continue
            }
            let body = String(string[string.index(after: index) ..< semicolon])
            if let decoded = decodeEntity(body) {
                result.append(decoded)
                index = string.index(after: semicolon)
            } else {
                result.append(character)
                index = string.index(after: index)
            }
        }
        return result
    }

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32? = if digits.hasPrefix("x") || digits.hasPrefix("X") {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits, radix: 10)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }

    /// Common named entities. Numeric forms cover the rest of Unicode.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "horbar": "\u{2015}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "hellip": "\u{2026}", "middot": "\u{00B7}", "bull": "\u{2022}", "dagger": "\u{2020}", "Dagger": "\u{2021}",
        "prime": "\u{2032}", "Prime": "\u{2033}", "permil": "\u{2030}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "cent": "\u{00A2}", "pound": "\u{00A3}", "curren": "\u{00A4}", "yen": "\u{00A5}", "euro": "\u{20AC}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "micro": "\u{00B5}",
        "deg": "\u{00B0}", "plusmn": "\u{00B1}", "sup1": "\u{00B9}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "minus": "\u{2212}",
        "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
        "szlig": "\u{00DF}", "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}",
        "atilde": "\u{00E3}", "auml": "\u{00E4}", "aring": "\u{00E5}", "aelig": "\u{00E6}",
        "ccedil": "\u{00E7}", "egrave": "\u{00E8}", "eacute": "\u{00E9}", "ecirc": "\u{00EA}", "euml": "\u{00EB}",
        "igrave": "\u{00EC}", "iacute": "\u{00ED}", "icirc": "\u{00EE}", "iuml": "\u{00EF}",
        "ntilde": "\u{00F1}", "ograve": "\u{00F2}", "oacute": "\u{00F3}", "ocirc": "\u{00F4}",
        "otilde": "\u{00F5}", "ouml": "\u{00F6}", "oslash": "\u{00F8}",
        "ugrave": "\u{00F9}", "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}",
        "yacute": "\u{00FD}", "yuml": "\u{00FF}",
        "Agrave": "\u{00C0}", "Aacute": "\u{00C1}", "Acirc": "\u{00C2}",
        "Atilde": "\u{00C3}", "Auml": "\u{00C4}", "Aring": "\u{00C5}", "AElig": "\u{00C6}",
        "Ccedil": "\u{00C7}", "Egrave": "\u{00C8}", "Eacute": "\u{00C9}", "Ecirc": "\u{00CA}", "Euml": "\u{00CB}",
        "Igrave": "\u{00CC}", "Iacute": "\u{00CD}", "Icirc": "\u{00CE}", "Iuml": "\u{00CF}",
        "Ntilde": "\u{00D1}", "Ograve": "\u{00D2}", "Oacute": "\u{00D3}", "Ocirc": "\u{00D4}",
        "Otilde": "\u{00D5}", "Ouml": "\u{00D6}", "Oslash": "\u{00D8}",
        "Ugrave": "\u{00D9}", "Uacute": "\u{00DA}", "Ucirc": "\u{00DB}", "Uuml": "\u{00DC}", "Yacute": "\u{00DD}",
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}",
        "pi": "\u{03C0}", "sigma": "\u{03C3}", "omega": "\u{03C9}",
        "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}", "harr": "\u{2194}",
        "star": "\u{2606}", "starf": "\u{2605}", "check": "\u{2713}", "cross": "\u{2717}",
        "infin": "\u{221E}", "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}", "asymp": "\u{2248}",
    ]
}
