import Foundation

enum UpdatePolicy {
    static func requiresMovingToApplications(_ path: String) -> Bool {
        path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }
}
