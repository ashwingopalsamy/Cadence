// S6 poster (unsandboxed CLI): post the Darwin notification named by the first argument, through
// CFNotificationCenter's Darwin center (the same notifications as notify_post).
import Foundation

guard CommandLine.arguments.count > 1 else { exit(2) }
let center = CFNotificationCenterGetDarwinNotifyCenter()
CFNotificationCenterPostNotification(center, CFNotificationName(CommandLine.arguments[1] as CFString), nil, nil, true)
print("notify_post status=0")
exit(0)
