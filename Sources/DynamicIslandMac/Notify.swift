import Foundation

let arguments = CommandLine.arguments
let title = arguments.count > 1 ? arguments[1] : "Live Activity"
let subtitle = arguments.count > 2 ? arguments[2] : "Update from your script"
let duration = arguments.count > 3 ? (Double(arguments[3]) ?? 5) : 5

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("local.siddharth.dynamicisland.activity"),
    object: nil,
    userInfo: ["title": title, "subtitle": subtitle, "duration": duration],
    deliverImmediately: true
)
