//
//  ELVLog+Categories.swift
//  EluviumCore
//
//  The package's log categories. Every Eluvium target depends on EluviumCore,
//  so `package` access reaches them all without exposing them to apps.
//

import Foundation

package extension ELVLog.Category {
    /// Pack loading, validation diagnostics, and merges.
    static let pack = ELVLog.Category("Pack")
    /// Remote pack refresh, download, and signature verification.
    static let remote = ELVLog.Category("Remote")
    /// Pipeline runs and their fetch steps.
    static let fetch = ELVLog.Category("Fetch")
    /// Field extraction and native ops.
    static let extract = ELVLog.Category("Extract")
    /// Headless DOM rendering.
    static let render = ELVLog.Category("Render")
    /// List-page enumeration walks.
    static let enumerate = ELVLog.Category("Enumerate")
    /// Archive imports.
    static let importer = ELVLog.Category("Import")
}
