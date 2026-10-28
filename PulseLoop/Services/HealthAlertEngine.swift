import Foundation

/// The rules a health alert can come from. Raw values key the once-per-day latch and the
/// notification identifiers, so **never rename**; append new cases.
enum HealthAlertKind: String, Codable, CaseIterable {
    case highHeartRateAtRest
    case lowHeartRateAwake
    case lowSpO2Night
    case restingHRRise
    case temperatureRise
    case combinedStrain
}

struct HealthAlert: Equatable {
    let kind: HealthAlertKind
    let title: String
    let body: String
}

/// Persisted latch state (UserDefaults JSON), so an alert fires at most once per kind per day and the
/// "no data" notice isn't repeated for the same last reading.
struct HealthAlertState: Codable, Equatable {
    /// `HealthAlertKind.rawValue` → day key (yyyy-MM-dd) it last fired.
    var firedOn: [String: String] = [:]
    /// `HealthAlertKind.rawValue` → start of the newest slot an instant alert fired on, so readings
    /// that straddle midnight can't fire the same alert again on the new day.
    var firedThrough: [String: Date] = [:]
    /// The last-reading time the "no data" notice was already scheduled or sent for.
    var noDataHandledFor: Date?
}

/// Pure, deterministic alert rules over the 15-minute ring slots (`RingSlotsExport.Slot`, the same
/// shape Vault Companion stores). No AI, no network. Instant rules (heart rate, SpO₂) look only at the
/// last few hours so a late sync never replays old events; "rise" rules compare last night against the
/// wearer's own median of earlier nights and stay silent until there are enough of them.
/// Not a diagnosis: thresholds are the owner's, wording is factual.
enum HealthAlertEngine {
    typealias Slot = RingSlotsExport.Slot

    /// Instant rules only consider readings this recent.
    static let recentWindow: TimeInterval = 6 * 3600
    /// Low-SpO₂ readings are counted over this window.
    static let spo2Window: TimeInterval = 12 * 3600
    static let spo2MinReadings = 3
    /// Two readings count as "in a row" when at most two slots (30 min) apart: the ring logs HR
    /// every 15–30 min depending on the interval setting.
    static let pairMaxGap: TimeInterval = 2 * RingSlotsExport.slotSeconds
    /// Steps per 15-minute slot below which the wearer is "barely moving".
    static let restStepsMax = 100
    /// A slot with at least this much light + deep sleep counts as asleep.
    static let asleepMinMinutes = 5
    /// Night medians need this many readings; baselines need this many earlier nights.
    static let nightMinReadings = 3
    static let baselineMinNights = 14
    static let baselineMaxNights = 28
    /// Comparisons with last night run from this local hour, once the night is over.
    static let morningHour = 7
    /// Awake-hours window (also when the "no data" notice may arrive).
    static let dayStartHour = 8
    static let dayEndHour = 22
    /// Combined-strain thresholds: all three must move together.
    static let strainRestingHRBpm = 3.0
    static let strainHRVFactor = 0.85
    static let strainTemperatureC = 0.3

    static func evaluate(
        slots: [Slot], prefs: HealthAlertPrefs, state: HealthAlertState, now: Date, calendar: Calendar = .current
    ) -> (alerts: [HealthAlert], state: HealthAlertState) {
        guard prefs.enabled else { return ([], state) }
        var newState = state
        var alerts: [HealthAlert] = []
        let today = dayKey(now, calendar)
        /// `trigger` (instant rules): the newest slot behind the alert; it must be newer than the last one fired.
        func fire(_ kind: HealthAlertKind, _ title: String, _ body: String, trigger: Date? = nil) {
            guard newState.firedOn[kind.rawValue] != today else { return }
            if let trigger {
                if let last = newState.firedThrough[kind.rawValue], trigger <= last { return }
                newState.firedThrough[kind.rawValue] = trigger
            }
            newState.firedOn[kind.rawValue] = today
            alerts.append(HealthAlert(kind: kind, title: title, body: body))
        }

        let sorted = slots.filter { $0.start <= now }.sorted { $0.start < $1.start }
        let recent = sorted.filter { $0.start >= now.addingTimeInterval(-recentWindow) }

        if prefs.highHeartRateEnabled, case let (a, b)? = latestPair(in: recent, where: {
            ($0.hr ?? 0) >= prefs.highHeartRateBpm && ($0.steps ?? 0) < restStepsMax
        }) {
            fire(.highHeartRateAtRest, "High heart rate at rest",
                 "\(a.hr ?? 0) bpm at \(clock(a.start, calendar)) and \(b.hr ?? 0) bpm at \(clock(b.start, calendar)) "
                    + "while barely moving. Your limit is \(prefs.highHeartRateBpm) bpm.", trigger: b.start)
        }

        if prefs.lowHeartRateEnabled, case let (a, b)? = latestPair(in: recent, where: {
            guard let hr = $0.hr else { return false }
            let hour = calendar.component(.hour, from: $0.start)
            return hr <= prefs.lowHeartRateBpm && !isAsleep($0) && hour >= dayStartHour && hour < dayEndHour
        }) {
            fire(.lowHeartRateAwake, "Low heart rate while awake",
                 "\(a.hr ?? 0) bpm at \(clock(a.start, calendar)) and \(b.hr ?? 0) bpm at \(clock(b.start, calendar)). "
                    + "Your limit is \(prefs.lowHeartRateBpm) bpm.", trigger: b.start)
        }

        if prefs.lowSpO2Enabled {
            let lowSlots = sorted.filter {
                $0.start >= now.addingTimeInterval(-spo2Window) && isNightTime($0, calendar)
                    && ($0.spo2 ?? 100) < prefs.lowSpO2Percent
            }
            let low = lowSlots.compactMap(\.spo2)
            if low.count >= spo2MinReadings, let lowest = low.min(), let newest = lowSlots.last {
                fire(.lowSpO2Night, "Low blood oxygen at night",
                     "\(low.count) readings below \(prefs.lowSpO2Percent)% in the last 12 hours, lowest \(lowest)%.",
                     trigger: newest.start)
            }
        }

        // Comparisons with your own normal: last night (keyed by its wake-up day) against earlier nights.
        if calendar.component(.hour, from: now) >= morningHour {
            let nights = nightSummaries(sorted, calendar)
            if let last = nights[today] {
                let earlier = nights.keys.filter { $0 < today }.sorted().suffix(baselineMaxNights).compactMap { nights[$0] }
                let baseHR = baseline(earlier.compactMap(\.restingHR))
                let baseHRV = baseline(earlier.compactMap(\.hrv))
                let baseTemp = baseline(earlier.compactMap(\.temperatureC))

                var strain = false
                if prefs.combinedStrainEnabled, let hr = last.restingHR, let hrv = last.hrv, let t = last.temperatureC,
                   let bHR = baseHR, let bHRV = baseHRV, let bT = baseTemp,
                   hr >= bHR.median + strainRestingHRBpm, hrv <= bHRV.median * strainHRVFactor,
                   t >= bT.median + strainTemperatureC {
                    strain = true
                    fire(.combinedStrain, "Possible strain or illness",
                         "Last night resting heart rate was \(Int(hr.rounded())) bpm (usual \(Int(bHR.median.rounded()))), "
                            + "HRV \(Int(hrv.rounded())) ms (usual \(Int(bHRV.median.rounded()))) and temperature "
                            + "\(oneDecimal(t)) °C (usual \(oneDecimal(bT.median))), all at once. Consider an easier day.")
                }
                if !strain, prefs.restingHRRiseEnabled, let hr = last.restingHR, let b = baseHR,
                   hr >= b.median + Double(prefs.restingHRRiseBpm) {
                    fire(.restingHRRise, "Resting heart rate is up",
                         "Last night's resting heart rate was \(Int(hr.rounded())) bpm, "
                            + "\(Int((hr - b.median).rounded())) above your usual \(Int(b.median.rounded())) "
                            + "(median of \(b.nights) nights).")
                }
                if !strain, prefs.temperatureRiseEnabled, let t = last.temperatureC, let b = baseTemp,
                   t >= b.median + prefs.temperatureRiseC {
                    fire(.temperatureRise, "Night temperature is up",
                         "Last night's temperature was \(oneDecimal(t)) °C, +\(oneDecimal(t - b.median)) above your usual "
                            + "\(oneDecimal(b.median)) °C (median of \(b.nights) nights).")
                }
            }
        }
        return (alerts, newState)
    }

    // MARK: - No-data notice

    /// When the "no ring data" notice should arrive: `hours` after the last reading, moved into the
    /// awake window (an evening gap is reported at 08:00 the next morning, not at midnight).
    static func noDataFireDate(lastReading: Date, hours: Int, calendar: Calendar = .current) -> Date {
        let due = lastReading.addingTimeInterval(Double(hours) * 3600)
        let hour = calendar.component(.hour, from: due)
        if hour < dayStartHour {
            return calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: due) ?? due
        }
        if hour >= dayEndHour, let next = calendar.date(byAdding: .day, value: 1, to: due) {
            return calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: next) ?? due
        }
        return due
    }

    /// Start of the newest slot that carries a heart-rate reading (the ring's most regular signal).
    static func lastReading(in slots: [Slot]) -> Date? {
        slots.filter { $0.hr != nil }.map(\.start).max()
    }

    // MARK: - Night summaries

    struct NightSummary: Equatable {
        var restingHR: Double?
        var hrv: Double?
        var temperatureC: Double?
    }

    /// Asleep slots grouped by wake-up day (a slot's start + 12 h), keeping only evening-to-noon slots so
    /// afternoon naps don't count. Each value is the median of that night's readings (HC4 option A).
    static func nightSummaries(_ slots: [Slot], _ calendar: Calendar) -> [String: NightSummary] {
        var hr: [String: [Double]] = [:], hrv: [String: [Double]] = [:], temp: [String: [Double]] = [:]
        for slot in slots where isAsleep(slot) {
            let hour = calendar.component(.hour, from: slot.start)
            guard hour >= 18 || hour < 12 else { continue }
            let key = dayKey(slot.start.addingTimeInterval(12 * 3600), calendar)
            if let v = slot.hr { hr[key, default: []].append(Double(v)) }
            if let v = slot.hrvMs { hrv[key, default: []].append(Double(v)) }
            if let v = slot.tempC { temp[key, default: []].append(v) }
        }
        var out: [String: NightSummary] = [:]
        for key in Set(hr.keys).union(hrv.keys).union(temp.keys) {
            out[key] = NightSummary(
                restingHR: nightMedian(hr[key]), hrv: nightMedian(hrv[key]), temperatureC: nightMedian(temp[key]))
        }
        return out
    }

    // MARK: - Helpers

    static func isAsleep(_ slot: Slot) -> Bool {
        (slot.sleepLightMin ?? 0) + (slot.sleepDeepMin ?? 0) >= asleepMinMinutes
    }

    private static func isNightTime(_ slot: Slot, _ calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: slot.start)
        return isAsleep(slot) || hour >= dayEndHour || hour < dayStartHour
    }

    /// The most recent two consecutive readings (heart-rate slots at most `pairMaxGap` apart) that
    /// both match. A single reading never alerts.
    private static func latestPair(in slots: [Slot], where match: (Slot) -> Bool) -> (Slot, Slot)? {
        let readings = slots.filter { $0.hr != nil }
        guard readings.count >= 2 else { return nil }
        for i in stride(from: readings.count - 1, through: 1, by: -1) {
            let a = readings[i - 1], b = readings[i]
            if b.start.timeIntervalSince(a.start) <= pairMaxGap, match(a), match(b) { return (a, b) }
        }
        return nil
    }

    private static func nightMedian(_ values: [Double]?) -> Double? {
        guard let values, values.count >= nightMinReadings else { return nil }
        return median(values)
    }

    private static func baseline(_ values: [Double]) -> (median: Double, nights: Int)? {
        guard values.count >= baselineMinNights, let m = median(values) else { return nil }
        return (m, values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }
}
