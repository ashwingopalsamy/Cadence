import Testing

@testable import CadenceMCP

@Suite struct MCPSmokeTests {
    @Test func revisions() {
        #expect(CadenceMCP.supportedRevisions == ["2026-07-28", "2025-11-25"])
    }
}
