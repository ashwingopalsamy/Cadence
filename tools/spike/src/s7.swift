// S7 probe: is the on-device language model usable?
import FoundationModels

switch SystemLanguageModel.default.availability {
case .available:
    print("available")
case .unavailable(let reason):
    print("unavailable: \(reason)")
@unknown default:
    print("unavailable: unknown")
}
