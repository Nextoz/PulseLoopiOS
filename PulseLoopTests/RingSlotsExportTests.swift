import XCTest
@testable import PulseLoop

/// "ring-slots/1" bucketing and JSON contract. All data is synthetic.
@MainActor
final class RingSlotsExportTests: XCTestCase {
    private typealias X = RingSlotsExport
    private let cph = TimeZone(identifier: "Europe/Copenhagen")!

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }
    private func sample(_ kind: MeasurementKind, _ v: Double, _ iso: String) -> X.Sample {
        X.Sample(kind: kind, value: v, timestamp: date(iso))
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBoundariesAndAggregation() {
        let base = now.addingTimeInterval(-3 * 3600)
        let slot0 = Date(timeIntervalSince1970: Double(X.slotKey(base)) * 900)
        let samples = [
            X.Sample(kind: .heartRate, value: 60, timestamp: slot0),                        // first second of slot
            X.Sample(kind: .heartRate, value: 71, timestamp: slot0.addingTimeInterval(899)), // last second of slot
            X.Sample(kind: .heartRate, value: 80, timestamp: slot0.addingTimeInterval(900)), // next slot
            X.Sample(kind: .spo2, value: 96, timestamp: slot0.addingTimeInterval(10)),
            X.Sample(kind: .spo2, value: 97, timestamp: slot0.addingTimeInterval(20)),
            X.Sample(kind: .temperature, value: 36.44, timestamp: slot0),
            X.Sample(kind: .temperature, value: 36.52, timestamp: slot0),
        ]
        let steps = [X.StepBucket(start: slot0, steps: 10), X.StepBucket(start: slot0.addingTimeInterval(300), steps: 5)]
        let slots = X.buildSlots(steps: steps, samples: samples, sleep: [], days: 1, now: now)
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots[0].start, slot0)
        XCTAssertEqual(slots[0].steps, 15)
        XCTAssertEqual(slots[0].hr, 66)       // mean(60, 71) = 65.5 -> 66
        XCTAssertEqual(slots[0].hrMin, 60)
        XCTAssertEqual(slots[0].hrMax, 71)
        XCTAssertEqual(slots[0].spo2, 97)     // mean 96.5 -> 97
        XCTAssertEqual(slots[0].tempC ?? 0, 36.5, accuracy: 0.0001)
        XCTAssertEqual(slots[1].start, slot0.addingTimeInterval(900))
        XCTAssertEqual(slots[1].hr, 80)
        XCTAssertNil(slots[1].steps, "no steps sample means null, never 0")
        XCTAssertNil(slots[1].spo2)
        // Local :00/:15/:30/:45 wall-clock boundary in a quarter-hour zone.
        XCTAssertEqual(Int(slots[0].start.timeIntervalSince1970) % 900, 0)
    }

    func testEmptySlotsAreOmittedAndWindowIsHonoured() {
        let outside = now.addingTimeInterval(-3 * 86_400)
        let slots = X.buildSlots(
            steps: [X.StepBucket(start: outside, steps: 50)],
            samples: [X.Sample(kind: .heartRate, value: 70, timestamp: outside)],
            sleep: [], days: 1, now: now)
        XCTAssertTrue(slots.isEmpty)
        // A recorded zero is real data and is kept; unknown sleep minutes are not.
        let kept = X.buildSlots(steps: [X.StepBucket(start: now.addingTimeInterval(-600), steps: 0)],
                                samples: [], sleep: [X.SleepBlock(start: now.addingTimeInterval(-600), minutes: 5, stage: .unknown)],
                                days: 1, now: now)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].steps, 0)
        XCTAssertNil(kept[0].sleepLightMin)
    }

    func testSleepMinutesSplitAcrossSlots() {
        let slot0 = Date(timeIntervalSince1970: Double(X.slotKey(now.addingTimeInterval(-7200))) * 900)
        // 20 light minutes starting 10 minutes before the slot boundary, then 5 deep.
        let start = slot0.addingTimeInterval(900 - 600)
        let slots = X.buildSlots(steps: [], samples: [],
            sleep: [X.SleepBlock(start: start, minutes: 20, stage: .light),
                    X.SleepBlock(start: start.addingTimeInterval(20 * 60), minutes: 5, stage: .deep),
                    X.SleepBlock(start: start.addingTimeInterval(25 * 60), minutes: 3, stage: .awake)],
            days: 1, now: now)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].sleepLightMin, 10)
        XCTAssertEqual(slots[1].sleepLightMin, 10)
        XCTAssertEqual(slots[1].sleepDeepMin, 5)
        XCTAssertNil(slots[1].sleepAwakeMin)
        XCTAssertEqual(slots[2].sleepAwakeMin, 3)
        XCTAssertNil(slots[0].sleepDeepMin)
    }

    func testDSTFallBackKeepsTheRepeatedHourDistinct() {
        // Europe/Copenhagen left DST on 2026-10-25: 02:30 happens twice (+02:00 then +01:00).
        let first = date("2026-10-25T02:30:00+02:00")
        let second = date("2026-10-25T02:30:00+01:00")
        let probe = date("2026-10-25T12:00:00+01:00")
        let slots = X.buildSlots(steps: [], samples: [
            X.Sample(kind: .heartRate, value: 60, timestamp: first),
            X.Sample(kind: .heartRate, value: 70, timestamp: second),
        ], sleep: [], days: 1, now: probe)
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots.map(\.hr), [60, 70])
        XCTAssertEqual(X.isoString(slots[0].start, timeZone: cph), "2026-10-25T02:30:00+02:00")
        XCTAssertEqual(X.isoString(slots[1].start, timeZone: cph), "2026-10-25T02:30:00+01:00")
        // Spring forward: 02:xx does not exist on 2026-03-29; 03:00+02:00 follows 01:45+01:00 directly.
        let before = date("2026-03-29T01:45:00+01:00")
        let after = date("2026-03-29T03:00:00+02:00")
        XCTAssertEqual(after.timeIntervalSince(before), 900)
        XCTAssertEqual(X.slotKey(after) - X.slotKey(before), 1)
    }

    func testExactJSONKeysAndNulls() throws {
        let slot = X.Slot(start: date("2026-10-27T03:15:00+01:00"), steps: 12, hr: 61, hrMin: 58, hrMax: 66,
                          spo2: nil, bpSys: nil, bpDia: nil, fatigue: nil, stress: nil, hrvMs: nil,
                          tempC: 36.5, sleepLightMin: 10, sleepDeepMin: nil, sleepAwakeMin: nil)
        let text = X.json(slots: [slot], device: "SMART_RING V138",
                          generatedAt: date("2026-10-27T09:00:00+01:00"), timeZone: cph)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Array(obj.keys).sorted(), ["device", "generatedAt", "schema", "slots"])
        XCTAssertEqual(obj["schema"] as? String, "ring-slots/1")
        XCTAssertEqual(obj["device"] as? String, "SMART_RING V138")
        XCTAssertEqual(obj["generatedAt"] as? String, "2026-10-27T09:00:00+01:00")
        let row = try XCTUnwrap((obj["slots"] as? [[String: Any]])?.first)
        XCTAssertEqual(Array(row.keys).sorted(), [
            "bpDia", "bpSys", "fatigue", "hr", "hrMax", "hrMin", "hrvMs", "sleepAwakeMin", "sleepDeepMin",
            "sleepLightMin", "spo2", "start", "steps", "stress", "tempC",
        ])
        XCTAssertEqual(row["start"] as? String, "2026-10-27T03:15:00+01:00")
        XCTAssertEqual(row["steps"] as? Int, 12)
        XCTAssertEqual(row["tempC"] as? Double, 36.5)
        XCTAssertTrue(row["spo2"] is NSNull)
        XCTAssertTrue(row["sleepDeepMin"] is NSNull)
        // Key order in the raw text follows the contract.
        XCTAssertTrue(text.hasPrefix("{\"schema\":\"ring-slots/1\",\"device\":\"SMART_RING V138\",\"generatedAt\":"))
        XCTAssertTrue(text.contains("\"slots\":[{\"start\":\"2026-10-27T03:15:00+01:00\",\"steps\":12,\"hr\":61,\"hrMin\":58,\"hrMax\":66,\"spo2\":null"))
        // Empty export is still valid JSON.
        let empty = X.json(slots: [], device: "x", generatedAt: now, timeZone: cph)
        XCTAssertTrue(empty.hasSuffix("\"slots\":[]}"))
    }

    func testDeviceLabelNeverCarriesAnAddress() {
        XCTAssertEqual(X.deviceLabel(name: "SMART_RING", firmware: "003A002AV138"), "SMART_RING V138")
        XCTAssertEqual(X.deviceLabel(name: nil, firmware: nil), "SMART_RING")
        XCTAssertEqual(X.deviceLabel(name: "SMART_RING AA:BB:CC:DD:EE:FF", firmware: "V138"), "SMART_RING V138")
        XCTAssertEqual(X.deviceLabel(name: "11111111-2222-3333-4444-555555555555", firmware: "9"), "SMART_RING V9")
    }

    func testExportFromStoreFiltersMockAndUsesBuckets() throws {
        let context = try TestSupport.makeContext()
        let t = Date().addingTimeInterval(-3600)
        context.insert(PulseLoop.Measurement(kind: .heartRate, value: 64, unit: "bpm", timestamp: t, source: .history))
        context.insert(PulseLoop.Measurement(kind: .heartRate, value: 150, unit: "bpm", timestamp: t, source: .mock))
        context.insert(ActivityBucketSample(timestamp: t, steps: 7, distanceMeters: 0))
        try context.save()
        let text = RingSlotsExport.export(days: 1, context: context)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(obj["slots"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["hr"] as? Int, 64)
        XCTAssertEqual(rows[0]["steps"] as? Int, 7)
    }
}
