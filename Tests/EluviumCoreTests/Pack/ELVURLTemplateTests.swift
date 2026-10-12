import Foundation
import Testing
@testable import EluviumCore

@Suite("URL templates")
struct ELVURLTemplateTests {
    @Test
    func `fill percent-encodes reserved characters so a param can never reshape the template`() {
        let filled = ELVURLTemplate.fill("https://api.example/v1/{param.id}?q={param.q}", params: ["id": "a&b#c d", "q": "x/y=z"])
        #expect(filled == "https://api.example/v1/a%26b%23c%20d?q=x%2Fy%3Dz")
        #expect(URL(string: filled) != nil)
        // Unreserved characters pass through; unfilled placeholders stay.
        #expect(ELVURLTemplate.fill("https://a/{param.slug}", params: ["slug": "hidden-falls_trail.v2~"]) == "https://a/hidden-falls_trail.v2~")
        #expect(ELVURLTemplate.fill("https://a/{param.missing}", params: [:]) == "https://a/{param.missing}")
    }

    @Test
    func `nativePlaceholderRegex captures the op reference and the param name`() throws {
        let template = "https://cdn.example/{native:x.syndicationToken@1(param.id)}/{param.id}"
        let regex = ELVURLTemplate.nativePlaceholderRegex
        let match = try #require(regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)))
        let nsTemplate = template as NSString
        #expect(nsTemplate.substring(with: match.range(at: 1)) == "x.syndicationToken@1")
        #expect(nsTemplate.substring(with: match.range(at: 2)) == "id")
        #expect(regex.numberOfMatches(in: "https://a/{param.id}", range: NSRange(location: 0, length: 20)) == 0)
    }

    @Test
    func `fillInput reads the input's query items, encodes them like params, and refuses a hole`() throws {
        let share = try #require(URL(string: "https://weread.qq.com/book-detail?type=1&v=d4a322a05d0f04d4a01f0d6&x=a%26b"))
        #expect(ELVURLTemplate.fillInput("https://weread.qq.com/web/bookDetail/{query.v}", from: share)
            == "https://weread.qq.com/web/bookDetail/d4a322a05d0f04d4a01f0d6")
        #expect(ELVURLTemplate.fillInput("https://a/{query.x}?t={query.type}", from: share) == "https://a/a%26b?t=1")
        // A template without input placeholders passes through untouched.
        #expect(ELVURLTemplate.fillInput("https://a/{param.id}", from: share) == "https://a/{param.id}")
        // Absent or empty items fail the fill rather than fetch a hole.
        #expect(ELVURLTemplate.fillInput("https://a/{query.missing}", from: share) == nil)
        let empty = try #require(URL(string: "https://weread.qq.com/book-detail?v="))
        #expect(ELVURLTemplate.fillInput("https://a/{query.v}", from: empty) == nil)
    }

    @Test
    func `fillInput substitutes the input's host, lowercased, and refuses a host it cannot vouch for`() throws {
        // Wikipedia serves its REST API on every language and mobile host,
        // so one template follows the pasted host instead of pinning one.
        let zh = try #require(URL(string: "https://zh.m.Wikipedia.org/wiki/%E4%B8%8A%E6%B5%B7%E5%B8%82"))
        #expect(ELVURLTemplate.fillInput("https://{host}/api/rest_v1/page/summary/{param.title}", from: zh)
            == "https://zh.m.wikipedia.org/api/rest_v1/page/summary/{param.title}")
        // Host and query placeholders fill together.
        let both = try #require(URL(string: "https://en.wikipedia.org/w/index.php?title=Jenny_Lake"))
        #expect(ELVURLTemplate.fillInput("https://{host}/x/{query.title}", from: both) == "https://en.wikipedia.org/x/Jenny_Lake")
        // No host (a file URL) is a hole, never a literal "{host}" fetch.
        let file = try #require(URL(string: "file:///tmp/page.html"))
        #expect(ELVURLTemplate.fillInput("https://{host}/api", from: file) == nil)
    }
}
