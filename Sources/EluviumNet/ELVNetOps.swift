import EluviumCore
import Foundation

/// Registers EluviumNet's native ops. An app that wants short-link chasing
/// calls `ELVNetOps.register()` once at startup; a binary that doesn't
/// skips every source requiring `native:shortlink.expand`.
public enum ELVNetOps {
    public static func register(expander: ELVShortLinkExpander = ELVShortLinkExpander()) {
        ELVNativeOps.registerAsync("shortlink.expand", version: 1) { input, context in
            let raw = input["url"] ?? context.url?.absoluteString
            guard let raw, let url = URL(string: raw), let expanded = try await expander.expand(url) else { return nil }
            return ["url": .url(expanded)]
        }
    }
}
