//
//  ELVLogFormat.swift
//  EluviumCore
//
//  Formatting shared by the package's log lines, so every target renders
//  durations and URLs the same way.
//

import Foundation

package enum ELVLogFormat {
    /// The only part of a URL public log text may carry. Share tokens live
    /// in paths and query strings (a Komoot `share_token`, a Swarm `?s=`, a
    /// shared-list path), so the full URL always goes in `private:`.
    package static func host(_ url: URL?) -> String {
        url?.host ?? "-"
    }

    /// Whole milliseconds, for `in 42ms` suffixes.
    package static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let total = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return total.isFinite ? Int(min(max(total, 0), 1e12).rounded()) : 0
    }
}
