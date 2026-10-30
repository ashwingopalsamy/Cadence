import Foundation
import Testing

@testable import CadenceCore

@Suite struct GenAIImportPreviewTests {
    @Test func dollarsAreExactIntegerFormatting() {
        #expect(GenAIImportPreview.dollars(micros: 0) == "$0.00")
        #expect(GenAIImportPreview.dollars(micros: 14_210_000) == "$14.21")
        #expect(GenAIImportPreview.dollars(micros: 4_995) == "$0.00")
        #expect(GenAIImportPreview.dollars(micros: 5_000) == "$0.01")
        #expect(GenAIImportPreview.dollars(micros: 1_234_567_890) == "$1,234.57")
        #expect(GenAIImportPreview.dollars(micros: 9_007_199_254_740_991) == "$9,007,199,254.74")
        #expect(GenAIImportPreview.dollars(micros: 2_500_000, estimated: true) == "~$2.50")
    }

    @Test func thousandsSeparators() {
        #expect(GenAIImportPreview.grouped(0) == "0")
        #expect(GenAIImportPreview.grouped(999) == "999")
        #expect(GenAIImportPreview.grouped(1000) == "1,000")
        #expect(GenAIImportPreview.grouped(1_602_551) == "1,602,551")
    }
}
