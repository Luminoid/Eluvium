import EluviumCore
import Foundation
import Testing

@Suite("Pack version ordering")
struct ELVPackVersionTests {
    @Test
    func `Versions order by the dotted date, then the trailing build, ignoring the label`() {
        #expect(ELVPackVersion.compare("2026.09.10-starter.2", "2026.10.10-starter.1") == .orderedAscending)
        #expect(ELVPackVersion.compare("2026.10.10-starter.2", "2026.10.10-starter.10") == .orderedAscending)
        #expect(ELVPackVersion.compare("2026.10.10-remote.3", "2026.10.10-starter.2") == .orderedDescending)
        #expect(ELVPackVersion.compare("2026.10.10-remote.2", "2026.10.10-starter.2") == .orderedSame)
        #expect(ELVPackVersion.compare("2026.10.10", "2026.10.10-starter.1") == .orderedAscending)
        // A bare date has build 0, never its own last component.
        #expect(ELVPackVersion.compare("2026.10.10", "2026.10.9-x.5") == .orderedDescending)
    }

    @Test
    func `Unparseable versions fall back to plain string order`() {
        #expect(ELVPackVersion.compare("base", "overlay") == .orderedAscending)
        #expect(ELVPackVersion.compare("t", "t") == .orderedSame)
        #expect(ELVPackVersion.compare("2026.10.10-starter.1", "beta") == .orderedAscending)
        // Too large for Int: no trap, string order.
        #expect(ELVPackVersion.compare("99999999999999999999.1", "2026.10.10") == .orderedDescending)
    }
}
