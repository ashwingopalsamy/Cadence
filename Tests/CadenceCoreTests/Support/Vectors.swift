import Foundation

@testable import CadenceCore

/// Shared fixtures in Tests/Vectors, located from this file's path so tests need no resources.
enum Vectors {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // CadenceCoreTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Vectors", isDirectory: true)

    static func json(_ relativePath: String) throws -> JSONValue {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try JSONParser.parse(bytes: Array(data))
    }
}
