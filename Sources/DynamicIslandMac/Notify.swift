import Foundation

let arguments = CommandLine.arguments
let title = arguments.count > 1 ? arguments[1] : "Live Activity"
let subtitle = arguments.count > 2 ? arguments[2] : "Update from your script"
let duration = arguments.count > 3 ? (Double(arguments[3]) ?? 5) : 5
let payload: [String: Any] = ["title": title, "subtitle": subtitle, "duration": duration]
let data = try JSONSerialization.data(withJSONObject: payload)
let destination = URL(fileURLWithPath: "/tmp/dynamic-island-mac-activity.json")
try data.write(to: destination, options: .atomic)
