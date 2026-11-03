// What the running app is allowed to do, read from its own code signature (docs/SPEC.md sections 4.6, 8.3 and 13).
// About says "Network calls by this app: None" only when this reading says so, never from a constant.
import Foundation
import Security

/// The sandbox and network entitlements a process or bundle carries.
public struct EntitlementReport: Sendable, Equatable {
    public static let sandboxKey = "com.apple.security.app-sandbox"
    public static let networkKeys = ["com.apple.security.network.client", "com.apple.security.network.server"]

    public var sandboxed: Bool
    /// Every network key that is present and true, in the order of `networkKeys`.
    public var networkKeys: [String]

    public init(sandboxed: Bool, networkKeys: [String]) {
        self.sandboxed = sandboxed
        self.networkKeys = networkKeys
    }

    /// No network key at all. On its own this does not stop a process outside the sandbox.
    public var hasNoNetworkKey: Bool { networkKeys.isEmpty }

    /// The OS blocks every connection: sandboxed and no network key.
    public var networkBlocked: Bool { sandboxed && networkKeys.isEmpty }

    /// The About row's value.
    public var networkSummary: String {
        if networkBlocked { return String(localized: "None. Read live from its entitlements.") }
        if !networkKeys.isEmpty { return String(localized: "Allowed by \(networkKeys.joined(separator: ", "))") }
        return String(localized: "Not blocked. This build runs outside the app sandbox.")
    }

    /// From an entitlements property list, such as the one embedded in a signature.
    public init(plist: [String: Any]) {
        sandboxed = (plist[Self.sandboxKey] as? Bool) == true
        networkKeys = Self.networkKeys.filter { (plist[$0] as? Bool) == true }
    }
}

public enum EntitlementReader {
    /// The running process, through `SecTask`. A process with no entitlements reads as not sandboxed with no
    /// network key, which is what an unsigned test runner is.
    public static func current() -> EntitlementReport {
        guard let task = SecTaskCreateFromSelf(nil) else { return EntitlementReport(sandboxed: false, networkKeys: []) }
        func flag(_ key: String) -> Bool {
            (SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool) == true
        }
        return EntitlementReport(
            sandboxed: flag(EntitlementReport.sandboxKey), networkKeys: EntitlementReport.networkKeys.filter(flag))
    }

    /// A signed bundle or binary on disk, through its embedded entitlements. Nil when it cannot be read.
    public static func signed(at url: URL) -> EntitlementReport? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return EntitlementReport(plist: entitlements)
    }

    /// An entitlements file such as `App/Cadence.entitlements`. Nil when it is not a property list.
    public static func file(at url: URL) -> EntitlementReport? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return EntitlementReport(plist: plist)
    }
}
