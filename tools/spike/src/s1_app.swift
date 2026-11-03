// S1 spike app: open a WAL SQLite file and write 50 rows. Needs: --db PATH --log PATH.
import Foundation
import SQLite3

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func log(_ s: String, to path: String) {
    try? (s + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

guard let dbPath = arg("--db"), let logPath = arg("--log") else { exit(2) }
let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
let prefix = "sandboxed=\(sandboxed ? "yes" : "no")\n"

var db: OpaquePointer?
guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
    log(prefix + "status=fail\nerror=open: \(String(cString: sqlite3_errmsg(db)))", to: logPath)
    exit(0)
}
sqlite3_busy_timeout(db, 5000)
for i in 0..<50 {
    if sqlite3_exec(db, "INSERT INTO t VALUES('app',\(i));", nil, nil, nil) != SQLITE_OK {
        log(prefix + "status=fail\nerror=insert \(i): \(String(cString: sqlite3_errmsg(db)))", to: logPath)
        exit(0)
    }
    usleep(20_000)
}
sqlite3_close(db)
log(prefix + "status=ok", to: logPath)
