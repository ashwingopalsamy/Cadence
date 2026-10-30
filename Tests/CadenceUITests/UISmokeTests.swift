import Testing

@testable import CadenceUI

@Suite struct UISmokeTests {
    @Test func moduleLoads() {
        _ = CadenceUI.self
    }
}
