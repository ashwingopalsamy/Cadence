import Testing

@testable import CadenceIngest

@Suite struct IngestSmokeTests {
    @Test func formatNames() {
        #expect(CadenceIngest.envelopeFormat == "envelope/1")
        #expect(CadenceIngest.mapFormat == "map/1")
    }
}
