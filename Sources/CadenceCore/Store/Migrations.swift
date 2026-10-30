/// Brings a store to the schema this binary understands (docs/SPEC.md section 7.3).
///
/// Runs under `BEGIN IMMEDIATE`, so two processes opening a fresh store at once cannot both
/// migrate it. A store at a newer version than this binary knows is never written to.
public enum Migrator {
    /// Migrates `db` to `Schema.currentVersion`. Returns the version it found.
    @discardableResult
    public static func migrate(_ db: SQLiteDatabase) throws(CadenceError) -> Int {
        do {
            // Fast path without the write lock: most opens find the store current.
            let seen = try db.userVersion()
            if seen == Schema.currentVersion { return seen }
            if seen > Schema.currentVersion {
                throw CadenceError.schemaTooNew(found: seen, supported: Schema.currentVersion)
            }
            return try db.transaction(.immediate) { () throws -> Int in
                let found = try db.userVersion()
                guard found <= Schema.currentVersion else {
                    throw CadenceError.schemaTooNew(found: found, supported: Schema.currentVersion)
                }
                for version in found..<Schema.currentVersion {
                    try db.execute(Schema.migrations[version])
                    try db.setUserVersion(version + 1)
                }
                return found
            }
        } catch let error as CadenceError {
            throw error
        } catch let error as SQLiteError {
            throw error.cadenceError
        } catch {
            throw .io(String(describing: error))
        }
    }

    /// Throws when the store is newer than this binary. Used before any write on an open connection.
    public static func checkWritable(_ db: SQLiteDatabase) throws(CadenceError) {
        let found: Int
        do {
            found = try db.userVersion()
        } catch {
            throw error.cadenceError
        }
        if found > Schema.currentVersion {
            throw .schemaTooNew(found: found, supported: Schema.currentVersion)
        }
    }
}
