// S6 poster (unsandboxed CLI): notify_post the name given as the first argument.
import Foundation

guard CommandLine.arguments.count > 1 else { exit(2) }
let status = notify_post(CommandLine.arguments[1])
print("notify_post status=\(status)")
exit(status == 0 ? 0 : 1)
