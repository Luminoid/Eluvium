import EluviumCore
import EluviumNet
import Foundation

/// Human copy for each typed failure state, distinct. Raw Swift
/// errors never reach the UI; everything routes through here.
enum FailureCopy {
    static func message(for failure: ELVFetchFailure) -> String {
        switch failure {
        case let .blocked(status): "The site blocked the request (HTTP \(status)), and escalating to a real browser render did not get through either."
        case let .httpError(status): "The server returned HTTP \(status)."
        case let .transport(code): "The connection failed before the server responded (network error \(code))."
        case .unauthenticated: "That resource needs you to be signed in."
        case .timeout: "The request timed out."
        case .offline: "You appear to be offline."
        case let .formatDrift(detail): "The page's format changed (\(detail))."
        case .invalidURL: "That URL is not valid."
        case let .egressBlocked(reason): "Blocked by egress policy: \(reason)."
        }
    }

    /// Copy for archive-import failures, matching the typed cases.
    static func message(for failure: ELVArchiveImporter.Failure) -> String {
        switch failure {
        case .unreadable: "That file could not be read as text."
        case let .unsupportedFormat(format): "The \(format) format is not supported for import."
        case let .formatMismatch(expected): "That file does not look like this source's export (expected columns: \(expected))."
        case .noRows: "No importable rows were found in that file."
        case let .tooLarge(limit): "That file is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) import limit."
        }
    }

    /// The shared no-match line for a resolve that found no source.
    static func unrecognized(host: String?) -> String {
        "No source matched \(host ?? "that host"), and no generic floor is installed."
    }
}
