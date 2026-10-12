import Foundation

/// The article-content op: `article.bodyFromPage@1` runs the readability
/// heuristic (`ELVArticleBody`) over the document in context, so the generic
/// floor can carry full-text `content` for article pages and a reader can
/// resolve a truncated feed item's link into its whole body. Pages without a
/// scoring body return nil, which invalidates only the calling candidate.
extension ELVNativeOps {
    static func registerArticleOps() {
        register("article.bodyFromPage", version: 1) { input, context in
            guard let html = input["html"] ?? context.document.html else { return nil }
            guard let extraction = ELVArticleBody.extract(html: html) else { return nil }
            return [
                "html": .text(extraction.html),
                "textLength": .number(Double(extraction.textLength)),
            ]
        }
    }
}
