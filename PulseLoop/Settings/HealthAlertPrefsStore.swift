import Foundation

/// User-tunable health alert rules, persisted as JSON in `UserDefaults`. Every rule defaults **on**
/// (the owner asked for alerts); limits are editable in Settings → Health Alerts. Tolerant decode, so
/// adding a key later never wipes a stored blob. Mirrors `AppleHealthPrefs`.
struct HealthAlertPrefs: Codable, Equatable {
    var enabled = true
    var highHeartRateEnabled = true
    var highHeartRateBpm = 110
    var lowHeartRateEnabled = true
    var lowHeartRateBpm = 40
    var lowSpO2Enabled = true
    var lowSpO2Percent = 90
    var restingHRRiseEnabled = true
    var restingHRRiseBpm = 7
    var temperatureRiseEnabled = true
    var temperatureRiseC = 0.5
    var combinedStrainEnabled = true
    var noDataEnabled = true
    var noDataHours = 6

    static let `default` = HealthAlertPrefs()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HealthAlertPrefs.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        highHeartRateEnabled = try c.decodeIfPresent(Bool.self, forKey: .highHeartRateEnabled) ?? d.highHeartRateEnabled
        highHeartRateBpm = try c.decodeIfPresent(Int.self, forKey: .highHeartRateBpm) ?? d.highHeartRateBpm
        lowHeartRateEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowHeartRateEnabled) ?? d.lowHeartRateEnabled
        lowHeartRateBpm = try c.decodeIfPresent(Int.self, forKey: .lowHeartRateBpm) ?? d.lowHeartRateBpm
        lowSpO2Enabled = try c.decodeIfPresent(Bool.self, forKey: .lowSpO2Enabled) ?? d.lowSpO2Enabled
        lowSpO2Percent = try c.decodeIfPresent(Int.self, forKey: .lowSpO2Percent) ?? d.lowSpO2Percent
        restingHRRiseEnabled = try c.decodeIfPresent(Bool.self, forKey: .restingHRRiseEnabled) ?? d.restingHRRiseEnabled
        restingHRRiseBpm = try c.decodeIfPresent(Int.self, forKey: .restingHRRiseBpm) ?? d.restingHRRiseBpm
        temperatureRiseEnabled = try c.decodeIfPresent(Bool.self, forKey: .temperatureRiseEnabled) ?? d.temperatureRiseEnabled
        temperatureRiseC = try c.decodeIfPresent(Double.self, forKey: .temperatureRiseC) ?? d.temperatureRiseC
        combinedStrainEnabled = try c.decodeIfPresent(Bool.self, forKey: .combinedStrainEnabled) ?? d.combinedStrainEnabled
        noDataEnabled = try c.decodeIfPresent(Bool.self, forKey: .noDataEnabled) ?? d.noDataEnabled
        noDataHours = try c.decodeIfPresent(Int.self, forKey: .noDataHours) ?? d.noDataHours
    }
}

/// Observable, `UserDefaults`-backed store for `HealthAlertPrefs`. Persists on `didSet`; the monitor
/// reads `prefs` at evaluation time, so a change applies to the next sync.
@MainActor
@Observable
final class HealthAlertPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = HealthAlertPrefsStore()

    private static let prefsKey = "pulseloop.healthalerts.prefs.v1"
    private let defaults: UserDefaults

    var prefs: HealthAlertPrefs {
        didSet {
            if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: Self.prefsKey) }
            if prefs.enabled != oldValue.enabled || prefs.noDataEnabled != oldValue.noDataEnabled
                || prefs.noDataHours != oldValue.noDataHours {
                HealthAlertMonitor.noDataPrefsChanged(prefs, defaults: defaults)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.prefsKey),
           let stored = try? JSONDecoder().decode(HealthAlertPrefs.self, from: data) {
            self.prefs = stored
        } else {
            self.prefs = .default
        }
    }
}
