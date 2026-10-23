import AppKit
import EventKit
import Observation

enum CalendarAccess: Equatable {
    case notDetermined, denied, restricted, authorized
    var actionTitle: String {
        switch self {
        case .authorized: return "Open Calendar"
        case .notDetermined: return "Allow Calendar Access"
        case .denied, .restricted: return "Open Settings"
        }
    }
    static func current() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

@MainActor @Observable final class CalendarService {
    private(set) var access = CalendarAccess.current()
    private(set) var events: [EKEvent] = []
    private(set) var enabled = false
    var onChange: (() -> Void)?
    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var midnightTimer: Timer?
    private var requesting = false

    func start() {
        guard !enabled else { return }
        enabled = true
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification,
                     .NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        enabled = false; events = []
        refreshTimer?.invalidate(); refreshTimer = nil
        midnightTimer?.invalidate(); midnightTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        DiagnosticsModel.shared.update(.calendar, .degraded, "Calendar disabled; observers and timers stopped")
        onChange?()
    }

    func requestAccess() {
        guard !requesting else { return }
        access = CalendarAccess.current()
        if access == .authorized { refresh(); return }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        guard access == .notDetermined else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
            return
        }
        requesting = true
        store.requestFullAccessToEvents { [weak self] _, error in
            let failure = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                self.requesting = false; self.refresh()
                if self.enabled, let failure { DiagnosticsModel.shared.update(.calendar, .failed, "Calendar request failed: \(failure)", event: true) }
                if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func refresh() {
        access = CalendarAccess.current()
        guard enabled else { onChange?(); return }
        guard access == .authorized else {
            events = []
            refreshTimer?.invalidate(); refreshTimer = nil
            midnightTimer?.invalidate(); midnightTimer = nil
            DiagnosticsModel.shared.update(.calendar, .failed, access == .notDetermined ? "Not requested — Allow Calendar Access" : "Calendar access unavailable — Open Settings")
            onChange?(); return
        }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).sorted(by: Self.precedes)
        DiagnosticsModel.shared.update(.calendar, .ok, "Full access · fetched \(events.count) events for today", event: true)
        if refreshTimer == nil {
            let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            timer.tolerance = 30; refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        midnightTimer?.invalidate()
        let midnight = Timer(fire: end.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        midnightTimer = midnight; RunLoop.main.add(midnight, forMode: .common)
        onChange?()
    }

    static func precedes(_ lhs: EKEvent, _ rhs: EKEvent) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        return lhs.startDate < rhs.startDate
    }

    func open() {
        guard access == .authorized else { requestAccess(); return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.open(url) }
    }
}
