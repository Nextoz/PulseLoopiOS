import Foundation
import SwiftData

/// Builds the "ring-slots/1" JSON contract consumed by Vault Companion: every stored ring sample
/// bucketed into 15-minute slots on local wall-clock boundaries, oldest first. Pure value logic plus a
/// thin SwiftData reader; local store only, no network.
enum RingSlotsExport {
    static let schema = "ring-slots/1"
    static let slotSeconds: TimeInterval = 900

    struct Sample {
        var kind: MeasurementKind
        var value: Double
        var timestamp: Date
    }
    struct StepBucket {
        var start: Date
        var steps: Int
    }
    struct SleepBlock {
        var start: Date
        var minutes: Int
        var stage: SleepStage
    }

    struct Slot: Equatable {
        var start: Date
        var steps: Int?
        var hr: Int?
        var hrMin: Int?
        var hrMax: Int?
        var spo2: Int?
        var bpSys: Int?
        var bpDia: Int?
        var fatigue: Int?
        var stress: Int?
        var hrvMs: Int?
        var tempC: Double?
        var sleepLightMin: Int?
        var sleepDeepMin: Int?
        var sleepAwakeMin: Int?

        var isEmpty: Bool {
            steps == nil && hr == nil && hrMin == nil && hrMax == nil && spo2 == nil && bpSys == nil
                && bpDia == nil && fatigue == nil && stress == nil && hrvMs == nil && tempC == nil
                && sleepLightMin == nil && sleepDeepMin == nil && sleepAwakeMin == nil
        }
    }

    /// Slot index for an instant. Local zone offsets are whole multiples of 15 minutes, so flooring
    /// the epoch lands on local :00/:15/:30/:45, including across DST changes.
    static func slotKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / slotSeconds).rounded(.down))
    }

    private struct Acc {
        var steps: Int?
        var values: [MeasurementKind: [Double]] = [:]
        var sleep: [SleepStage: Int] = [:]
    }

    static func buildSlots(
        steps: [StepBucket], samples: [Sample], sleep: [SleepBlock],
        days: Int, now: Date
    ) -> [Slot] {
        let days = min(28, max(1, days))
        let windowStart = slotKey(now.addingTimeInterval(-Double(days) * 86_400))
        let windowEnd = slotKey(now)
        var accs: [Int: Acc] = [:]
        func inWindow(_ key: Int) -> Bool { key >= windowStart && key <= windowEnd }

        for b in steps {
            let k = slotKey(b.start)
            guard inWindow(k) else { continue }
            accs[k, default: Acc()].steps = (accs[k]?.steps ?? 0) + b.steps
        }
        for s in samples {
            let k = slotKey(s.timestamp)
            guard inWindow(k) else { continue }
            accs[k, default: Acc()].values[s.kind, default: []].append(s.value)
        }
        for block in sleep where block.minutes > 0 {
            for m in 0..<block.minutes {
                let k = slotKey(block.start.addingTimeInterval(Double(m) * 60))
                guard inWindow(k) else { continue }
                accs[k, default: Acc()].sleep[block.stage, default: 0] += 1
            }
        }

        func mean(_ v: [Double]?) -> Double? {
            guard let v, !v.isEmpty else { return nil }
            return v.reduce(0, +) / Double(v.count)
        }
        func rounded(_ v: [Double]?) -> Int? { mean(v).map { Int($0.rounded()) } }

        return accs.keys.sorted().compactMap { key -> Slot? in
            guard let a = accs[key] else { return nil }
            let hrValues = a.values[.heartRate]
            let slot = Slot(
                start: Date(timeIntervalSince1970: Double(key) * slotSeconds),
                steps: a.steps,
                hr: rounded(hrValues),
                hrMin: hrValues?.min().map { Int($0.rounded()) },
                hrMax: hrValues?.max().map { Int($0.rounded()) },
                spo2: rounded(a.values[.spo2]),
                bpSys: rounded(a.values[.bloodPressureSystolic]),
                bpDia: rounded(a.values[.bloodPressureDiastolic]),
                fatigue: rounded(a.values[.fatigue]),
                stress: rounded(a.values[.stress]),
                hrvMs: rounded(a.values[.hrv]),
                tempC: mean(a.values[.temperature]).map { ($0 * 10).rounded() / 10 },
                sleepLightMin: a.sleep[.light],
                sleepDeepMin: a.sleep[.deep],
                sleepAwakeMin: a.sleep[.awake]
            )
            return slot.isEmpty ? nil : slot
        }
    }

    // MARK: - JSON

    static func isoString(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// Device label "<ring name> V<fw>". Never includes a Bluetooth address.
    static func deviceLabel(name: String?, firmware: String?) -> String {
        var base = (name ?? "").trimmingCharacters(in: .whitespaces)
        base = scrubAddresses(base)
        if base.isEmpty { base = "SMART_RING" }
        var fw = (firmware ?? "").trimmingCharacters(in: .whitespaces)
        // Firmware strings look like "003A002AV138": keep only the version after the last "V".
        if let r = fw.range(of: "V", options: .backwards), r.upperBound < fw.endIndex {
            fw = String(fw[r.upperBound...])
        }
        fw = scrubAddresses(fw)
        return fw.isEmpty ? base : "\(base) V\(fw)"
    }

    /// Drop anything shaped like a MAC address or CoreBluetooth UUID.
    static func scrubAddresses(_ s: String) -> String {
        var out = s
        for pattern in ["([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}",
                        "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func json(slots: [Slot], device: String, generatedAt: Date, timeZone: TimeZone = .current) -> String {
        func i(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        func d(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "null" }
        let rows = slots.map { s in
            "{\"start\":\(quote(isoString(s.start, timeZone: timeZone)))"
                + ",\"steps\":\(i(s.steps)),\"hr\":\(i(s.hr)),\"hrMin\":\(i(s.hrMin)),\"hrMax\":\(i(s.hrMax))"
                + ",\"spo2\":\(i(s.spo2)),\"bpSys\":\(i(s.bpSys)),\"bpDia\":\(i(s.bpDia))"
                + ",\"fatigue\":\(i(s.fatigue)),\"stress\":\(i(s.stress)),\"hrvMs\":\(i(s.hrvMs))"
                + ",\"tempC\":\(d(s.tempC)),\"sleepLightMin\":\(i(s.sleepLightMin))"
                + ",\"sleepDeepMin\":\(i(s.sleepDeepMin)),\"sleepAwakeMin\":\(i(s.sleepAwakeMin))}"
        }
        return "{\"schema\":\(quote(schema)),\"device\":\(quote(device))"
            + ",\"generatedAt\":\(quote(isoString(generatedAt, timeZone: timeZone)))"
            + ",\"slots\":[\(rows.joined(separator: ","))]}"
    }

    // MARK: - Store reader

    /// Every stored ring sample from the last `days` days as 15-minute slots (also read by the
    /// on-device health alerts, so alerts and Vault Companion see the same numbers).
    @MainActor
    static func slots(days: Int, context: ModelContext, now: Date = Date()) -> [Slot] {
        let days = min(28, max(1, days))
        let from = now.addingTimeInterval(-Double(days) * 86_400 - 86_400)
        let mockRaw = MeasurementSource.mock.rawValue

        let buckets = (try? context.fetch(FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.timestamp >= from }))) ?? []
        let rows = (try? context.fetch(FetchDescriptor<PulseLoop.Measurement>(
            predicate: #Predicate { $0.timestamp >= from && $0.sourceRaw != mockRaw }))) ?? []
        let blocks = (try? context.fetch(FetchDescriptor<SleepStageBlock>(
            predicate: #Predicate { $0.startAt >= from }))) ?? []

        return buildSlots(
            steps: buckets.map { StepBucket(start: $0.timestamp, steps: $0.steps) },
            samples: rows.compactMap { r in
                MeasurementKind(rawValue: r.kindRaw).map { Sample(kind: $0, value: r.value, timestamp: r.timestamp) }
            },
            sleep: blocks.map {
                SleepBlock(start: $0.startAt, minutes: $0.durationMinutes, stage: SleepStage(rawValue: $0.stageRaw) ?? .unknown)
            },
            days: days, now: now)
    }

    @MainActor
    static func export(days: Int, context: ModelContext, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let built = Self.slots(days: days, context: context, now: now)
        let device = DeviceRepository.current(context: context)
        let label = deviceLabel(name: device?.advertisedName ?? device?.name, firmware: device?.firmwareVersion)
        return json(slots: built, device: label, generatedAt: now, timeZone: timeZone)
    }
}
