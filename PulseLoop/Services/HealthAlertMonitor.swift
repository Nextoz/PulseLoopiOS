import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Runs `HealthAlertEngine` after every completed ring history sync and delivers its alerts as local
/// notifications. Also keeps one pending "no ring data" notification scheduled `noDataHours` after
/// the newest reading: every sync with fresh data pushes it forward, so it only arrives when syncs stop
/// bringing data (ring off, flat, out of range). On-device only, no AI. Lives for the app lifetime,
/// like `BatteryAlertMonitor`; started from `PulseLoopApp`.
@MainActor
final class HealthAlertMonitor {
    static let stateKey = "pulseloop.healthalerts.state.v1"
    static let noDataIdentifier = "health.alert.nodata"
    /// Baselines compare up to 28 earlier nights, the most `RingSlotsExport.slots` reads.
    static let historyDays = 28

    private let context: ModelContext
    private let defaults: UserDefaults
    private var streamTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    /// Short settle window after `"done"` so `EventPersistenceSubscriber` has written the last samples
    /// (bus fan-out order isn't guaranteed), and back-to-back completions coalesce.
    private let debounceSeconds: UInt64 = 3

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
    }

    deinit {
        streamTask?.cancel()
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: PulseEvent) {
        guard case let .syncProgress(stage) = event, stage == "done" else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceSeconds ?? 3) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.runAfterSync()
        }
    }

    private func runAfterSync() async {
        // A background BLE wake grants only ~10 s; ask for the standard finite-task extension.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "health.alerts") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        await evaluate(now: Date())
    }

    /// One evaluation pass: instant and baseline rules, then the no-data reschedule.
    func evaluate(now: Date) async {
        let prefs = HealthAlertPrefsStore.shared.prefs
        if prefs.enabled, UIApplication.shared.applicationState == .active { await Self.requestPermissionIfNeeded() }
        let slots = RingSlotsExport.slots(days: Self.historyDays, context: context, now: now)
        let result = HealthAlertEngine.evaluate(slots: slots, prefs: prefs, state: loadState(), now: now)
        let alerts = result.alerts
        var state = result.state
        await updateNoData(prefs: prefs, lastReading: HealthAlertEngine.lastReading(in: slots), now: now, state: &state)
        saveState(state)
        for alert in alerts {
            await Self.deliver(identifier: "health.alert.\(alert.kind.rawValue)", title: alert.title, body: alert.body)
        }
    }

    private func updateNoData(prefs: HealthAlertPrefs, lastReading: Date?, now: Date, state: inout HealthAlertState) async {
        let center = UNUserNotificationCenter.current()
        guard prefs.enabled, prefs.noDataEnabled, let lastReading else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.noDataIdentifier])
            state.noDataHandledFor = nil   // re-enabling schedules afresh
            return
        }
        // Each last reading is handled once: scheduled ahead, or sent now when already overdue.
        guard state.noDataHandledFor != lastReading else { return }
        state.noDataHandledFor = lastReading
        // Already overdue at night → the next 08:00, not now (the hours-0 date is "now, moved into the day").
        let fireAt = max(HealthAlertEngine.noDataFireDate(lastReading: lastReading, hours: prefs.noDataHours),
                         HealthAlertEngine.noDataFireDate(lastReading: now, hours: 0))
        let since = lastReading.formatted(date: .omitted, time: .shortened)
        let delay = fireAt.timeIntervalSince(now)
        await Self.deliver(
            identifier: Self.noDataIdentifier,
            title: "No new ring data",
            body: "No readings from your ring since \(since). Is it on your finger, charged and near the phone?",
            after: delay > 1 ? delay : nil)
    }

    /// Settings changed the no-data rule: drop a pending notice when it's now off, and forget which
    /// reading was handled so the next sync schedules with the new hours.
    static func noDataPrefsChanged(_ prefs: HealthAlertPrefs, defaults: UserDefaults = .standard) {
        if !prefs.enabled || !prefs.noDataEnabled {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [noDataIdentifier])
        }
        guard let data = defaults.data(forKey: stateKey),
              var state = try? JSONDecoder().decode(HealthAlertState.self, from: data) else { return }
        state.noDataHandledFor = nil
        if let out = try? JSONEncoder().encode(state) { defaults.set(out, forKey: stateKey) }
    }

    // MARK: - Persisted state

    private func loadState() -> HealthAlertState {
        guard let data = defaults.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(HealthAlertState.self, from: data) else {
            return HealthAlertState()
        }
        return state
    }

    private func saveState(_ state: HealthAlertState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    // MARK: - Delivery

    /// Ask for notification permission while the app is in front (from the Health Alerts screen);
    /// a background pass can't show the system prompt.
    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// A plain local notification; `after` schedules it (same identifier replaces a pending one).
    /// Silently skipped when notifications aren't allowed.
    static func deliver(identifier: String, title: String, body: String, after: TimeInterval? = nil) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = after.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
