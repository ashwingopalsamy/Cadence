import CadenceCore
import Foundation

/// Where the app reads the store (docs/SPEC.md sections 7.4 and 8.3).
///
/// In the sandbox `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` return the app's
/// container, not the real home, and the entitlement allows only `~/Library/Application Support/Cadence/`.
/// So the real home comes from the password database, which the sandbox does not rewrite.
///
/// `CADENCE_HOME`, when set, is the store and nothing else is: a path the sandbox denies makes the read
/// fail and the error state show. There is no fallback to the real store, which a development run must
/// never touch by accident.
public enum StoreLocation: Sendable, Equatable {
    case found(FileRoots)
    /// The location could not be worked out at all.
    case failed(StoreFailure)

    /// Pure: `realHome` comes from `StoreLocation.realHome()` in the app and is passed in by tests.
    public static func resolve(environment: [String: String], realHome: URL?) -> StoreLocation {
        guard let realHome else {
            // With no home to expand against, only an absolute CADENCE_HOME can still be understood.
            if let explicit = environment["CADENCE_HOME"], explicit.hasPrefix("/") {
                return .found(FileRoots(home: URL(fileURLWithPath: explicit, isDirectory: true)))
            }
            return .failed(StoreFailure(detail: "Cadence could not find your home folder"))
        }
        return .found(FileRoots.resolve(environment: environment, userHome: realHome))
    }

    /// The signed-in user's real home folder from `getpwuid(getuid())`, or nil if the lookup fails.
    public static func realHome() -> URL? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let path = String(cString: directory)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The database file the observer watches, or nil when the location is unknown.
    public var databasePath: String? {
        if case .found(let roots) = self { return roots.database.path }
        return nil
    }
}
